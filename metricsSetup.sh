#!/usr/bin/env bash

#set -x #echo on

######################################################################################
## This script is used to setup AWS CloudWatch Metrics for API Performance Testing data
## API Performance Testing objects is transformed into customized CloudMetrics data and makes it easier to search the results better in aws.
## 
##
## This script performs following tasks:
## 1. Setup Various CloudMetrics in AWS
##  
## !! This script is executed from local terminal. !!
## 
## PREREQUISITES for launching this script:
## 1. IAM User already exists that is set in AWS Profile
## 2. AWS profile is already set in AWS CLI (aws configure) locally based on the enviorment (dev, beta, staging, prod)
## 3. jq exsits
## 
## ~~~~~~~~~~~~~~ USAGE ~~~~~~~~~~~~~~
## $ ./metricsSetup.sh <env>
##
## Example: ./metricsSetup.sh [-f] dev
## 
## Arguements:
## 1. env - The environment on AWS where the infrastructure will be created
##    Possible Values: dev (For Local Development Testing on AWS)
##                     beta (For Beta Environment on AWS)
##                     staging (For Staging Environment on AWS)
##                     prod (For Production Environment on AWS)
##                     externalQA (For Development Testing on AWS)
##                     uat (For Beta Environment on AWS)
## 
## Options:
## -f - Create all resources again 'forcefully' by removing previous one if found existed
## ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
##
######################################################################################

curr_dir=
infra_config=
errCol=$(tput setaf 1)
succCol=$(tput setaf 2)
noteCol=$(tput setaf 3)
ul=$(tput smul)
high=$(tput bold)
reset=$(tput sgr0)

if [ "$#" -lt "1" ]; then
    echo && echo -e "${errCol}Insufficient Arguements provided${errCol}${reset}" && echo
    echo "Usage:"
    echo "$ ./$(basename $0) [-f] <env>" && echo
    echo "env can be dev/beta/staging/prod/externalQA/uat" && echo
    exit 1
fi

force=false
while getopts "f:" opt;do
	case $opt in
		f)  force=true
            shift $(( $OPTIND - 2 ))
            ;;
		*) echo -e "${errCol}\nInvalid Option Provided.${errCol}${reset}\n"; exit 1;;
	esac
done

# Determine the OS Type
osName="$(uname -s)"
case "${osName}" in
    Linux*)     curr_dir=$( dirname "$(readlink -f -- "$0")" );;
    Darwin*)    curr_dir=$(pwd);;
    *)          curr_dir=$( dirname "$(readlink -f -- "$0")" )
esac

getConfig(){
    echo | grep ^$1$2= $curr_dir/../.conf | cut -d'=' -f2
}

getInfraEnvConfig(){
    echo | grep ^$1= $infra_config/.env.${env} | cut -d'=' -f2
}


## Function :: Verify if CloudWatch Metric already exists or not ##
isMetricExists(){
    IS_METRIC_EXISTS=false
    echo -e "\n-> Verifying if Metric for '$1' already exists...\n" >&2

    $awsCommand logs describe-metric-filters \
        --region $AWS_REGION \
        --profile $AWS_PROFILE \
        --metric-name ${3} \
        --metric-namespace ${2} > temp.json 2>&1 || true

    if ! cat temp.json | grep -q "error occurred" && ! cat temp.json | grep -q "Error"  
    then
        if jq -e '.metricFilters | select(type == "array" and length >= 1)' temp.json >/dev/null
        then
            IS_METRIC_EXISTS=true

            METRIC_NAME=$(jq --raw-output '.metricFilters[0].metricTransformations[0].metricName' temp.json) || true

            echo -e "\n '${METRIC_NAME}' Metric Found ${succCol}Existed.${succCol}${reset}.\n" >&2

            if [ ${force} == true ]
            then
                IS_METRIC_EXISTS=false

                $awsCommand logs delete-metric-filter \
                    --region $AWS_REGION \
                    --profile $AWS_PROFILE \
                    --filter-name ${4} > temp.json 2>&1 || true

                if [ $? -eq 0 ]; then
                    echo -e "\n Previous Metric ${noteCol}is Dropped${noteCol}${reset}.\n" >&2
                    echo -e "\n New Metric will be ${noteCol}re-created${noteCol}${reset}.\n" >&2
                else
                    echo -e "\n ${errCol}ERROR${errCol}${reset} !! Failed to delete Metric, Program will exit\n\n" >&2
                    exit 1
                fi
            fi
        else
            IS_METRIC_EXISTS=false
            echo -e "\n '${3}' Metric ${noteCol}Not Found Existed${noteCol}${reset}.\n" >&2
        fi
    fi

    echo $IS_METRIC_EXISTS
}

## Function :: Create new CloudWatch Metrics ##
createMetric(){
    echo -e "\n-> Creating New Metric for '${1}'...\n" >&2

    namespace=${2}
    namespace=${namespace//'/'/\\/}
    namespace=''$namespace''

    metricname=${3}
    metricname=${metricname//'/'/\\/}
    metricname=''$metricname''

    metricTempFile=$(echo ${5} | cut -d "." -f1)
    metricTempFile="$metricTempFile-temp.json"

    cp ${5} $metricTempFile
    sed -i -e 's/\(NAMESPACE_PH\)/'${namespace}'/' $metricTempFile
    sed -i -e 's/\(METRICNAME_PH\)/'${metricname}'/' $metricTempFile

    $awsCommand logs put-metric-filter \
        --region $AWS_REGION \
        --profile $AWS_PROFILE \
        --log-group-name ${METRIC_SOURCE_LOGGROUP} \
        --filter-name ${4} \
        --filter-pattern "${6}" \
        --metric-transformations file://${metricTempFile}

    if [ $? -eq 0 ]; then
        echo -e "\n New Metric for '${1}' created ${succCol}successfully${succCol}${reset}.\n" >&2
    else
        echo -e "\n ${errCol}ERROR${errCol}${reset} !! Failed to create New Metric for '${1}', Program will exit\n\n" >&2
        exit 1
    fi

    rm -rf $metricTempFile
}


env=$1
env_upper=$(echo ${env} | tr [:lower:] [:upper:])    #Capitialize env
env_formatted=
infra_config=$curr_dir/../../infraSetup/envs
isSuccessfull=false

#Constants
awsCommand=aws
ENV_TYPE_DEV=dev
ENV_TYPE_BETA=beta
ENV_TYPE_STAGING=staging
ENV_TYPE_PROD=prod
ENV_TYPE_CONF=externalQA
ENV_TYPE_CONF=uat
seperator=\|

#Metric Resources Namings
METRIC_SOURCE_LOGGROUP="$env-cd"

METRIC_NAMESPACE_BASE=CFD/$env/PerformanceTesting
METRIC_NAMESPACE_STAFF=${METRIC_NAMESPACE_BASE}/Staff
METRIC_NAMESPACE_PATIENT=${METRIC_NAMESPACE_BASE}/Patient

METRIC_FILTER_NAME_REQUESTS_AVG='RequestsVolumeAvg'
METRIC_FILTER_PATTERN_REQUESTS_AVG='{$.moduleType = "MODULE_PH" && $.title = "*"}'
METRIC_NAME_REQUESTS_AVG='AllRequestsVolume_[reqs/sec]'

METRIC_FILTER_NAME_LATENCY_AVG='LatencyAvg'
METRIC_FILTER_PATTERN_LATENCY_AVG='{$.moduleType = "MODULE_PH" && $.title = "*"}'
METRIC_NAME_LATENCY_AVG='AllLatency_[ms]'

METRIC_FILTER_NAME_THROUGHPUT_AVG='ThroughPutAvg'
METRIC_FILTER_THROUGHPUT_REQUESTS_AVG='{$.moduleType = "MODULE_PH" && $.title = "*"}'
METRIC_NAME_THROUGHPUT_AVG='AllThroughPut_[bytes/sec]'

METRIC_FILTER_NAME_200RESPONSES_AVG='HTTP200Response'
METRIC_FILTER_PATTERN_200RESPONSES_AVG='{$.moduleType = "MODULE_PH" && $.title = "*" && $._2xxCodeCount > 0 && $.non2xxCodeCount = 0}'
METRIC_NAME_200RESPONSES_AVG='AllHTTP_200'

METRIC_FILTER_NAME_400RESPONSES_AVG='HTTP400Response'
METRIC_FILTER_PATTERN_400RESPONSES_AVG='{$.moduleType = "MODULE_PH" && $.title = "*" && $._4xxCodeCount > 0}'
METRIC_NAME_400RESPONSES_AVG='AllHTTP_400'

METRIC_FILTER_NAME_500RESPONSES_AVG='HTTP500Response'
METRIC_FILTER_PATTERN_500RESPONSES_AVG='{$.moduleType = "MODULE_PH" && $.title = "*" && $._5xxCodeCount > 0}'
METRIC_NAME_500RESPONSES_AVG='AllHTTP_500'

METRIC_FILTER_NAME_ERRORS='Errors'
METRIC_FILTER_PATTERN_ERRORS='{$.moduleType = "MODULE_PH" && $.title = "*" && $.errorsCount > 0}'
METRIC_NAME_ERRORS='AllErrors'

METRIC_FILTER_NAME_TIMEOUTS='Timeouts'
METRIC_FILTER_PATTERN_TIMEOUTS='{$.moduleType = "MODULE_PH" && $.title = "*" && $.timeoutsCount > 0}'
METRIC_NAME_TIMEOUTS='AllTimeouts'

#Supported Files Location
doc_metric_error=$curr_dir/documents/metric_error_responses.json
doc_metric_http200=$curr_dir/documents/metric_http200_responses.json
doc_metric_http400=$curr_dir/documents/metric_http400_responses.json
doc_metric_http500=$curr_dir/documents/metric_http500_responses.json
doc_metric_latency_avg=$curr_dir/documents/metric_latency_avg.json
doc_metric_requests_avg=$curr_dir/documents/metric_requestsVolume_avg.json
doc_metric_throughput_avg=$curr_dir/documents/metric_throughput_avg.json
doc_metric_timeouts=$curr_dir/documents/metric_timeouts.json


if [ "$env" != "$ENV_TYPE_DEV" ] && [ "$env" != "$ENV_TYPE_BETA" ] && [ "$env" != "$ENV_TYPE_STAGING" ] && [ "$env" != "$ENV_TYPE_PROD" ] && [ "$env" != "$ENV_TYPE_CONF" ] && [ "$env" != "$ENV_TYPE_CONF" ]
then
    echo && echo -e "${errCol}Invalid Environment provided, please enter valid Environment: dev/beta/staging/prod/externalQA/uat${errCol}${reset}" && echo
    exit 1
fi

ENV_SHORT=$(echo $env_upper | cut -c 1-4)

if [ "$env" == "$ENV_TYPE_CONF" ] || [ "$env" == "$ENV_TYPE_CONF" ]; then
    env_formatted=${ENV_SHORT}
else
    env_formatted=${env_upper}
fi
env_lower=$(echo ${env_formatted} | tr [:upper:] [:lower:])

## Check if all prerequisties are setup

if [[ $(command -v aws) == "" ]]; then
    echo -e "\n${errCol}AWS CLI not found present in the system. Please install AWS CLI v2 https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html ${errCol}${reset}" && echo
    exit 1;
fi

if ! jq --version > /dev/null 2>&1 
then 
   echo "jq not found installed. Please install it first." && echo
   exit 1
fi


## Get Configured Properties
AWS_PROFILE=$(getConfig 'PROFILE_NAME_' ${env_formatted})
AWS_ACCOUNT_ID=$(getInfraEnvConfig 'AWS_ACCOUNT_ID')
AWS_REGION=$(getInfraEnvConfig 'AWS_REGION')


echo -e "\n========================================================================"
echo "CloudWatch Metrics Setup for 'API Performance Testing' on AWS started..." 
echo "========================================================================"

echo
echo "----------------------------------------------------"
echo "AWS Account ID:           $AWS_ACCOUNT_ID" 
echo "AWS Profile:              $AWS_PROFILE"            
echo "AWS Region:               $AWS_REGION"
echo "ENV:                      $env"
echo "----------------------------------------------------"
echo


## Setup Metrics for 'Staff' and 'Patient' 

modulesCons=staff${seperator}patient
metricNamespaceCons=${METRIC_NAMESPACE_STAFF}${seperator}${METRIC_NAMESPACE_PATIENT}
modulesCtr=2

ctr=1
while [ $ctr -lt $modulesCtr ] || [ $ctr -eq $modulesCtr ]
do
    moduleName=$(echo $modulesCons | cut -d "${seperator}" -f ${ctr})
    metricNamespace=$(echo $metricNamespaceCons | cut -d "${seperator}" -f ${ctr})

    moduleName_upper=$(echo ${moduleName} | tr [:lower:] [:upper:])

    echo -e "${high}${ul}\n==> Creating Various Metrics for '$moduleName'...\n${ul}${high}${reset}"


    ## Setup Metric for 'Latency [Average]'

    echo -e "${high}\n=> Setting up Metric for 'Latency [Average]'...\n${high}${reset}"

    filterName=$moduleName'_'${METRIC_FILTER_NAME_LATENCY_AVG}

    #Check if Metric already created
    IS_METRIC_EXISTS=$(isMetricExists 'Latency [Average]' ${metricNamespace} ${METRIC_NAME_LATENCY_AVG} ${filterName})

    #Create new Metric
    if [ ${IS_METRIC_EXISTS} == false ]
    then
        filterPattern=$(echo ${METRIC_FILTER_PATTERN_LATENCY_AVG} | sed -e 's/\(MODULE_PH\)/'${moduleName}'/')

        createMetric 'Latency [Average]' ${metricNamespace} ${METRIC_NAME_LATENCY_AVG} ${filterName} ${doc_metric_latency_avg} "${filterPattern}"
        
    fi


    ## Setup Metric for 'Request Volume [Average]'

    echo -e "${high}\n=> Setting up Metric for 'Request Volume [Average]'...\n${high}${reset}"

    filterName=$moduleName'_'${METRIC_FILTER_NAME_REQUESTS_AVG}

    #Check if Metric already created
    IS_METRIC_EXISTS=$(isMetricExists 'Request Volume [Average]' ${metricNamespace} ${METRIC_NAME_REQUESTS_AVG} ${filterName})

    #Create new Metric
    if [ ${IS_METRIC_EXISTS} == false ]
    then
		filterPattern=$(echo ${METRIC_FILTER_PATTERN_REQUESTS_AVG} | sed -e 's/\(MODULE_PH\)/'${moduleName}'/')
		
        createMetric 'Request Volume [Average]' ${metricNamespace} ${METRIC_NAME_REQUESTS_AVG} ${filterName} ${doc_metric_requests_avg} "${filterPattern}"
        
    fi
	
	
	## Setup Metric for 'ThroughPut [Average]'

    echo -e "${high}\n=> Setting up Metric for 'ThroughPut [Average]'...\n${high}${reset}"
	
	filterName=$moduleName'_'${METRIC_FILTER_NAME_THROUGHPUT_AVG}

    #Check if Metric already created
    IS_METRIC_EXISTS=$(isMetricExists 'ThroughPut [Average]' ${metricNamespace} ${METRIC_NAME_THROUGHPUT_AVG} ${filterName})

    #Create new Metric
    if [ ${IS_METRIC_EXISTS} == false ]
    then
		filterPattern=$(echo ${METRIC_FILTER_THROUGHPUT_REQUESTS_AVG} | sed -e 's/\(MODULE_PH\)/'${moduleName}'/')
		
        createMetric 'ThroughPut [Average]' ${metricNamespace} ${METRIC_NAME_THROUGHPUT_AVG} ${filterName} ${doc_metric_throughput_avg} "${filterPattern}"
        
    fi
	
	
	## Setup Metric for 'HTTP 200 Responses'

    echo -e "${high}\n=> Setting up Metric for 'HTTP 200 Responses'...\n${high}${reset}"
	
	filterName=$moduleName'_'${METRIC_FILTER_NAME_200RESPONSES_AVG}

    #Check if Metric already created
    IS_METRIC_EXISTS=$(isMetricExists 'HTTP 200 Responses' ${metricNamespace} ${METRIC_NAME_200RESPONSES_AVG} ${filterName})

    #Create new Metric
    if [ ${IS_METRIC_EXISTS} == false ]
    then
		filterPattern=$(echo ${METRIC_FILTER_PATTERN_200RESPONSES_AVG} | sed -e 's/\(MODULE_PH\)/'${moduleName}'/')
		
        createMetric 'HTTP 200 Responses' ${metricNamespace} ${METRIC_NAME_200RESPONSES_AVG} ${filterName} ${doc_metric_http200} "${filterPattern}"
        
    fi
	
	
	## Setup Metric for 'HTTP 400 Responses'

    echo -e "${high}\n=> Setting up Metric for 'HTTP 400 Responses'...\n${high}${reset}"
	
	filterName=$moduleName'_'${METRIC_FILTER_NAME_400RESPONSES_AVG}

    #Check if Metric already created
    IS_METRIC_EXISTS=$(isMetricExists 'HTTP 400 Responses' ${metricNamespace} ${METRIC_NAME_400RESPONSES_AVG} ${filterName})

    #Create new Metric
    if [ ${IS_METRIC_EXISTS} == false ]
    then
		filterPattern=$(echo ${METRIC_FILTER_PATTERN_400RESPONSES_AVG} | sed -e 's/\(MODULE_PH\)/'${moduleName}'/')
		
        createMetric 'HTTP 400 Responses' ${metricNamespace} ${METRIC_NAME_400RESPONSES_AVG} ${filterName} ${doc_metric_http400} "${filterPattern}"
        
    fi
	
	
	## Setup Metric for 'HTTP 500 Responses'

    echo -e "${high}\n=> Setting up Metric for 'HTTP 500 Responses'...\n${high}${reset}"
	
	filterName=$moduleName'_'${METRIC_FILTER_NAME_500RESPONSES_AVG}

    #Check if Metric already created
    IS_METRIC_EXISTS=$(isMetricExists 'HTTP 500 Responses' ${metricNamespace} ${METRIC_NAME_500RESPONSES_AVG} ${filterName})

    #Create new Metric
    if [ ${IS_METRIC_EXISTS} == false ]
    then
		filterPattern=$(echo ${METRIC_FILTER_PATTERN_500RESPONSES_AVG} | sed -e 's/\(MODULE_PH\)/'${moduleName}'/')
		
        createMetric 'HTTP 500 Responses' ${metricNamespace} ${METRIC_NAME_500RESPONSES_AVG} ${filterName} ${doc_metric_http500} "${filterPattern}"
        
    fi
	
	
	## Setup Metric for 'Error Responses'

    echo -e "${high}\n=> Setting up Metric for 'Error Responses'...\n${high}${reset}"
	
	filterName=$moduleName'_'${METRIC_FILTER_NAME_ERRORS}

    #Check if Metric already created
    IS_METRIC_EXISTS=$(isMetricExists 'Error Responses' ${metricNamespace} ${METRIC_NAME_ERRORS} ${filterName})

    #Create new Metric
    if [ ${IS_METRIC_EXISTS} == false ]
    then
		filterPattern=$(echo ${METRIC_FILTER_PATTERN_ERRORS} | sed -e 's/\(MODULE_PH\)/'${moduleName}'/')
		
        createMetric 'Error Responses' ${metricNamespace} ${METRIC_NAME_ERRORS} ${filterName} ${doc_metric_error} "${filterPattern}"
        
    fi
	
	
	## Setup Metric for 'Timeout'

    echo -e "${high}\n=> Setting up Metric for 'Timeout'...\n${high}${reset}"
	
	filterName=$moduleName'_'${METRIC_FILTER_NAME_TIMEOUTS}

    #Check if Metric already created
    IS_METRIC_EXISTS=$(isMetricExists 'Timeout' ${metricNamespace} ${METRIC_NAME_TIMEOUTS} ${filterName})

    #Create new Metric
    if [ ${IS_METRIC_EXISTS} == false ]
    then
		filterPattern=$(echo ${METRIC_FILTER_PATTERN_TIMEOUTS} | sed -e 's/\(MODULE_PH\)/'${moduleName}'/')
		
        createMetric 'Timeout' ${metricNamespace} ${METRIC_NAME_TIMEOUTS} ${filterName} ${doc_metric_timeouts} "${filterPattern}"        
        
    fi

    if [ $ctr -eq $modulesCtr ]; then
        isSuccessfull=true
    fi


    ctr=$(($ctr+1))
done


rm -rf temp.json


if [ $? -eq 0  ] && [ ${isSuccessfull} == true ]; then
    echo -e "\n========================================================================================"
    echo -e "CloudWatch Metrics Setup for 'API Performance Testing' on AWS Finished ${succCol}SUCCESSFULLY${succCol}${reset}. " 
    echo "========================================================================================"
else
    echo -e "\n!! CloudWatch Metrics Setup for 'API Performance Testing' on AWS ${errCol}FAILED${errCol}${reset}. !!"
fi

echo

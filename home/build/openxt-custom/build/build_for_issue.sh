#!/bin/bash

#Query Jira REST Api for information about issue
#Get Github pull request information
#Set overrides so that engage_srcrevs will override relevant recipes.
#PRs for xenclient-oe and openxt repos need to be handled as special cases...sigh
set -ex

ISSUE=$1

extract_url () {
    arg=$1
    echo $( echo ${pr_response} | python -c "import json,sys;obj=json.load(sys.stdin);print obj['detail'][0]['pullRequests'][${arg}]['source']['url']" )
}

extract_status () {
    arg=$1
    echo ${pr_response} | python -c "import json,sys;obj=json.load(sys.stdin);print obj['detail'][0]['pullRequests'][${arg}]['status']"
    
}

extract_branch () {
    arg=$1
    echo $( echo ${pr_response} | python -c "import json,sys;obj=json.load(sys.stdin);print obj['detail'][0]['pullRequests'][${arg}]['source']['branch']" )
}


#make sure we strip away everything that's not in the json object
response=$( curl -X GET -H "Content-Type: application/json" https://openxt.atlassian.net/rest/api/2/issue/${ISSUE} )

#grab the id out of the json response
id=$( echo $response | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["id"]' )

#use id to query for pull request information
pr_response=$( curl -X GET -H "Content-Type: application/json" "https://openxt.atlassian.net/rest/dev-status/1.0/issue/detail?issueId=${id}&applicationType=github&dataType=pullrequest" )

#grep pr_response for number of PRs
num_prs=$( echo $pr_response | grep -o "status" | wc -l )

for i in $(seq 1 ${num_prs}); do
    pr_status=$( extract_status $((${i} - 1)) )
    if [[ ${pr_status} == "OPEN" ]]; then
        long_url=$( extract_url $((${i} - 1)) )
        repo=$( echo ${long_url} | cut -f 5 -d '/' )
        git="$( echo ${long_url} | cut -f 3 -d '/' )/$( echo ${long_url} | cut -f 4 -d '/' )"
        branch=$( extract_branch $((${i} - 1)) )
        repo_list=${repo_list}"${repo}:${git}:${branch},"
    fi
done

echo ${repo_list}

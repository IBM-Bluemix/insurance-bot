#!/bin/bash
echo Login IBM Cloud api=$CF_TARGET_URL org=$CF_ORG space=$CF_SPACE
bx login -a "$CF_TARGET_URL" --apikey "$IAM_API_KEY" -o "$CF_ORG" -s "$CF_SPACE"

# The branch may use a custom manifest
MANIFEST=manifest.yml
PREFIX=""
if [ -f ${REPO_BRANCH}-manifest.yml ]; then
  MANIFEST=${REPO_BRANCH}-manifest.yml
  PREFIX=$REPO_BRANCH"-"
fi
echo "Using manifest file: $MANIFEST"
echo "Using prefix: $PREFIX"

if [ -z "$ASSISTANT_PLAN" ]; then
  export ASSISTANT_PLAN=free
fi
echo "ASSISTANT_PLAN=$ASSISTANT_PLAN"

if [ -z "$CLOUDANT_PLAN" ]; then
  export CLOUDANT_PLAN=Lite
fi
echo "CLOUDANT_PLAN=$CLOUDANT_PLAN"

# Create services
bx service create conversation ${ASSISTANT_PLAN} ${PREFIX}insurance-bot-conversation
bx service create cloudantNoSQLDB ${CLOUDANT_PLAN} ${PREFIX}insurance-bot-db
bx service create appid "Graduated tier" ${PREFIX}insurance-bot-appid

# Set up App ID service
# Note: We only configure Cloud Directory and don't turn Google / Facebook off
#
# Create service key from which to obtain managementUrl
bx service key-create ${PREFIX}insurance-bot-appid for-pipeline
# managementUrl includes tenantId
APPID_MGMT_URL=`bx service key-show ${PREFIX}insurance-bot-appid for-pipeline | grep "\"managementUrl\"" | awk '{print $2}' | tr -d '","'`
# We need the IAM token
IAM_OAUTH_TOKEN=`bx iam oauth-tokens | sed -n 1p | awk 'NF>1{print $NF}'`
# Now configure App ID for Cloud Directory
FILENAME=".bluemix/appid-config.json"
curl -v -X PUT --header 'Content-Type: application/json' --header 'Accept: application/json' \
           --header "Authorization: Bearer $IAM_OAUTH_TOKEN" \
           -d @$FILENAME  $APPID_MGMT_URL/config/idps/cloud_directory

# Deploy the app
if ! bx app show $CF_APP; then
  bx app push $CF_APP -n $CF_APP -f ${MANIFEST} --no-start
  if [ ! -z "$CONVERSATION_WORKSPACE" ]; then
    bx cf set-env $CF_APP CONVERSATION_WORKSPACE $CONVERSATION_WORKSPACE
  fi
  bx cf start $CF_APP
else
  OLD_CF_APP=${CF_APP}-OLD-$(date +"%s")
  rollback() {
    set +e
    if bx app show $OLD_CF_APP; then
      bx app logs $CF_APP --recent
      bx app delete $CF_APP -f
      bx app rename $OLD_CF_APP $CF_APP
    fi
    exit 1
  }
  set -e
  trap rollback ERR
  bx app rename $CF_APP $OLD_CF_APP
  bx app push $CF_APP -n $CF_APP -f ${MANIFEST} --no-start
  if [ ! -z "$CONVERSATION_WORKSPACE" ]; then
    bx cf set-env $CF_APP CONVERSATION_WORKSPACE $CONVERSATION_WORKSPACE
  fi
  bx cf start $CF_APP
  bx app delete $OLD_CF_APP -f
fi

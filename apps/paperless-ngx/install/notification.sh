#!/bin/sh

DATE="$(date '+%Y.%m.%d %H:%M')"

BODY="[paperless] [✅] A document ${DOCUMENT_ORIGINAL_FILENAME} was just consumed. Correspondent - ${DOCUMENT_CORRESPONDENT} || Tags - ${DOCUMENT_TAGS}"

TYPE="success"
TITLE="[k3s] Successfull document consumption"
TAG="paperless"

DATA='{"tag":"'${TAG}'","type":"'${TYPE}'","body":"'${BODY}'","title":"'${TITLE}'"}'

curl -X POST --data "${DATA}" -H "Content-Type: application/json" "http://apprise.apprise.svc.cluster.local:8000/notify/apprise"

exit $?

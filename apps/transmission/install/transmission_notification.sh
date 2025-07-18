#!/bin/sh
#
# Send push notification to Apprise when a torrent is complete.
#
# Requires: Apprise server, Transmission torrent client and curl.
#
# Available environment variables from Transmission (as of v2.83) are:
#
# TR_APP_VERSION
# TR_TIME_LOCALTIME
# TR_TORRENT_DIR
# TR_TORRENT_HASH
# TR_TORRENT_ID
# TR_TORRENT_NAME
#

DATE="$(date '+%Y.%m.%d %H:%M')"

# Message for the notification.
TYPE="success"
NAME="${TR_TORRENT_NAME}"
BODY="[transmission] [✅] ${NAME} finished downloading on archer at ${DATE}."
TITLE="[k3s] Download complete"
TAG="transmission"

DATA='{"tag":"'${TAG}'","type":"'${TYPE}'","body":"'${BODY}'","title":"'${TITLE}'"}'

curl -X POST --data "${DATA}" -H "Content-Type: application/json" "http://apprise.apprise.svc.cluster.local:8000/notify/apprise"

exit $?

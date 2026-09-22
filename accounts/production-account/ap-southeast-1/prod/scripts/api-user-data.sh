From adc05f8ddda33e3918ef09c1cf5a45a2fffcfe82 Mon Sep 17 00:00:00 2001
From: Claude <noreply@anthropic.com>
Date: Tue, 22 Sep 2026 09:49:36 +0530
Subject: [PATCH] Fix missing AdminPortal__BaseUrl in ASG launch template
 user-data

Program.cs requires AdminPortal:BaseUrl at startup and throws if it's
missing -- this is exactly what caused the production outage during
tonight's manual redeploy (fixed live at the time by hand). That fix
was never brought back into this script: the ASG launch template's
user-data still didn't set it, so any ASG-driven instance launch
(scale-out, instance refresh, AWS host retirement) was one boot away
from repeating that outage automatically, with nobody there to catch
it via a manual restart.

Fix: pull /shalotrack/prod/api/admin_portal_base_url from SSM and pass
it through, with the same fail-fast guard already used for the DB
connection strings -- abort the boot cleanly instead of letting the
container crash-loop.

Also drops GpsArchive__Region -- set here but never read anywhere in
the C# codebase (confirmed via grep), dead config left over from an
earlier pass.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01K6BnW4N4xu8eR4KqANTUVM
---
 .../prod/scripts/api-user-data.sh             | 31 +++++++++++++------
 1 file changed, 21 insertions(+), 10 deletions(-)

diff --git a/accounts/production-account/ap-southeast-1/prod/scripts/api-user-data.sh b/accounts/production-account/ap-southeast-1/prod/scripts/api-user-data.sh
index 175f164..f89ef54 100644
--- a/accounts/production-account/ap-southeast-1/prod/scripts/api-user-data.sh
+++ b/accounts/production-account/ap-southeast-1/prod/scripts/api-user-data.sh
@@ -29,6 +29,26 @@ API_ADMIN_SYNC_KEY=$(aws ssm get-parameter \
   --name "/shalotrack/prod/api/admin_sync_key" \
   --with-decryption --query "Parameter.Value" --output text)
 
+# BAN FIX-STYLE GUARD (2026-09-22): AdminPortal:BaseUrl is a hard-required
+# startup config key (see Program.cs -- the app throws and refuses to start
+# without it). This was missing from this script entirely until now: the
+# manual docker run script used for hotfix deploys had it patched in by
+# hand after a real production outage, but that fix was never brought back
+# into this file. Any ASG-driven instance launch (scale-out, instance
+# refresh, AWS host retirement) was one crash-loop away from repeating that
+# exact outage, silently, with nobody there to catch it. Same fail-fast
+# guard as the connection strings above: abort the boot cleanly instead of
+# letting the container crash-loop.
+API_ADMIN_PORTAL_BASE_URL=$(aws ssm get-parameter \
+  --name "/shalotrack/prod/api/admin_portal_base_url" \
+  --with-decryption --query "Parameter.Value" --output text)
+
+if [ -z "$API_ADMIN_PORTAL_BASE_URL" ]; then
+  echo "FATAL: /shalotrack/prod/api/admin_portal_base_url is missing or empty in SSM."
+  echo "FATAL: Aborting EC2 boot -- the API throws on startup without AdminPortal:BaseUrl."
+  exit 1
+fi
+
 API_REALTIME_CONNECTION_STRING=$(aws ssm get-parameter \
   --name "/shalotrack/prod/api/realtime_connection_string" \
   --with-decryption --query "Parameter.Value" --output text)
@@ -70,15 +90,6 @@ if [ -z "$GPS_ARCHIVE_BUCKET_NAME" ]; then
   echo "WARNING: gps_archive_bucket_name not found in SSM — falling back to hardcoded default"
 fi
 
-# GPS ARCHIVE: AWS region for S3 client inside the container.
-GPS_ARCHIVE_REGION=$(aws ssm get-parameter \
-  --name "/shalotrack/prod/api/gps_archive_region" \
-  --query "Parameter.Value" --output text)
-if [ -z "$GPS_ARCHIVE_REGION" ]; then
-  GPS_ARCHIVE_REGION="ap-southeast-1"
-  echo "WARNING: gps_archive_region not found in SSM — defaulting to ap-southeast-1"
-fi
-
 # GPS ARCHIVE: PurgeDryRun flag — controls whether archived GPS rows are
 # actually deleted from Supabase after being written to S3.
 #
@@ -121,10 +132,10 @@ docker run -d --restart always --name shalotrack-api \
   -e ConnectionStrings__DefaultConnection="$API_CONNECTION_STRING" \
   -e ConnectionStrings__RealtimeConnection="$API_REALTIME_CONNECTION_STRING" \
   -e AdminSync__Key="$API_ADMIN_SYNC_KEY" \
+  -e AdminPortal__BaseUrl="$API_ADMIN_PORTAL_BASE_URL" \
   -e Firebase__ServiceAccountJson="$API_FIREBASE_SERVICE_ACCOUNT_JSON" \
   -e GoogleMaps__RoadsApiKey="$API_GOOGLE_MAPS_ROADS_API_KEY" \
   -e GpsArchive__BucketName="$GPS_ARCHIVE_BUCKET_NAME" \
-  -e GpsArchive__Region="$GPS_ARCHIVE_REGION" \
   -e GpsArchive__PurgeDryRun="$GPS_ARCHIVE_PURGE_DRY_RUN" \
   ${ecr_url}:latest
 
-- 
2.43.0

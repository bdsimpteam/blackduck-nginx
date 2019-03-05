#!/bin/sh

if [ ! -f "$WEBSERVER_HOME/bin/certmanager.sh" ];
then
  echo "ERROR: Cert manager shell script is not present."
  exit 1
fi

HUB_WEBSERVER=hub-webserver

# HOST/PORT DEFINITION FOR OTHER HUB SERVICES
targetCAHost="${HUB_CFSSL_HOST:-cfssl}"
targetCAPort="${HUB_CFSSL_PORT:-8888}"
targetAuthenticationHost="${HUB_AUTHENTICATION_HOST:-authentication}"
targetAuthenticationPort="${HUB_AUTHENTICATION_PORT:-8443}"
targetWebAppHost="${HUB_WEBAPP_HOST:-webapp}"
targetWebAppPort="${HUB_WEBAPP_PORT:-8443}"
targetScanHost="${HUB_SCAN_HOST:-scan}"
targetScanPort="${HUB_SCAN_PORT:-8443}"
targetDocHost="${HUB_DOC_HOST:-documentation}"
targetDocPort="${HUB_DOC_PORT:-8443}"
targetJobrunnerHost="${HUB_JOBRUNNER_HOST:-jobrunner}"
targetJobrunnerPort="${HUB_JOBRUNNER_PORT:-7070}"

# HOST/PORT DEFINITION FOR THE WEBSERVER SERVICE
targetWebserverHost="${HUB_WEBSERVER_HOST:-webserver}"
targetWebserverPort="${HUB_WEBSERVER_PORT:-8443}"
publicWebserverHost="${PUBLIC_HUB_WEBSERVER_HOST:-localhost}"
publicWebserverPort="${PUBLIC_HUB_WEBSERVER_PORT:-443}"

certPath="${WEBSERVER_CERT_PATH:-$WEBSERVER_HOME/security/$HUB_WEBSERVER.crt}"
keyPath="${WEBSERVER_KEY_PATH:-$WEBSERVER_HOME/security/$HUB_WEBSERVER.key}"
rootCertPath="${WEBSERVER_ROOT_CERT_PATH:-$WEBSERVER_HOME/security/root.crt}"
sslProtocols="${TLS_PROTOCOLS:-TLSv1.2}"
requestHeaderSize="${HUB_REQUEST_HEADER_SIZE:-8k}"
allowDenyAccessDirectives=""

exposeMetricsExternally="${EXPOSE_METRICS_EXTERNALLY:-false}"

# /run/secrets is not always an option (for example, there are OSE behaviour conflicts when mounting).
secretsMountPath="${RUN_SECRETS_DIR:-/run/secrets}"

echo "Certificate authority host: $targetCAHost"
echo "Certificate authority port: $targetCAPort"
echo "Authentication host: $targetAuthenticationHost"
echo "Authentication port: $targetAuthenticationPort"
echo "Webapp host: $targetWebAppHost"
echo "Webapp port: $targetWebAppPort"
echo "Scan host: $targetScanHost"
echo "Scan port: $targetScanPort"
echo "Webserver host: $targetWebserverHost"
echo "Webserver port: $targetWebserverPort"
echo "Public webserver host: $publicWebserverHost"
echo "Public webserver port: $publicWebserverPort"
[ -z "$PUBLIC_HUB_WEBSERVER_HOST" ] && echo "Public Webserver Host: [$publicWebserverHost]. Wrong host name? Restart the container with the right host name configured in hub-webserver.env"

createSelfSignedServerCert() {
  echo "Attempting to generate Hub webserver key and certificate."
  $WEBSERVER_HOME/bin/certmanager.sh server-cert \
      --ca $targetCAHost:$targetCAPort \
      --rootcert $WEBSERVER_HOME/security/root.crt \
      --key $keyPath \
      --cert $certPath \
      --outputDirectory $WEBSERVER_HOME/security \
      --commonName $HUB_WEBSERVER \
      --san $targetWebserverHost \
      --san $publicWebserverHost \
      --san localhost \
      --hostName $publicWebserverHost
  exitCode=$?
  if [ $exitCode -eq 0 ];
  then
    echo "Generated Hub webserver key and certificate."
    chmod 644 $WEBSERVER_HOME/security/root.crt
    chmod 400 $keyPath
    chmod 644 $certPath

  else
    echo "ERROR: Unable to generate Hub webserver key and certificate (Code: $exitCode)."
    exit $exitCode
  fi
}

createBlackduckSystemClientCertificate() {
    echo "Attempting to generate Hub Client key and certificate."
    ${WEBSERVER_HOME}/bin/certmanager.sh client-cert \
                                         --ca $targetCAHost:$targetCAPort \
                                         --outputDirectory ${WEBSERVER_HOME}/security \
                                         --commonName blackduck_system
    exitCode=$?
    if [ $exitCode -eq 0 ];
    then
        chmod 400 ${WEBSERVER_HOME}/security/blackduck_system.key
        chmod 644 ${WEBSERVER_HOME}/security/blackduck_system.crt
    else
        echo "Unable to create Hub client certificate (Code: $exitCode)."
        exit $exitCode
    fi
}

manageRootCertificate() {
    $WEBSERVER_HOME/bin/certmanager.sh root \
        --ca $targetCAHost:$targetCAPort \
        --outputDirectory $WEBSERVER_HOME/security \
        --profile peer
}

validateAllowDenyAccessDirective() {
  echo "$1" | grep -q ';'
  exitCode=$?
  if [ $exitCode -eq 0 ];
  then
    echo "ERROR: Allow / deny access directive is invalid: $1 (Code: $exitCode)"
    exit 1
  fi
}

manageAllowDenyAccessDirectives() {
  if [ -n "$DENY_ACCESS_DIRECTIVES" ] || [ -n "$ALLOW_ACCESS_DIRECTIVES" ];
  then
    # Allow and/or deny access directives are defined, so configure them.
    allowDenyAccessDirectives="allow 10.0.0.0\/8;\n"
    allowDenyAccessDirectives="${allowDenyAccessDirectives}    allow 172.16.0.0\/12;\n"
    allowDenyAccessDirectives="${allowDenyAccessDirectives}    allow 192.168.0.0\/16;\n"
    allowDenyAccessDirectives="${allowDenyAccessDirectives}    allow 169.254.0.0\/16;\n"
    allowDenyAccessDirectives="${allowDenyAccessDirectives}    allow 127.0.0.0\/8;\n"

    if [ -z "$IPV4_ONLY" ] || [ -n "$IPV4_ONLY" -a "$IPV4_ONLY" -ne "1" ];
    then
      allowDenyAccessDirectives="${allowDenyAccessDirectives}    allow fd00::\/8;\n"
      allowDenyAccessDirectives="${allowDenyAccessDirectives}    allow ::1\/128;\n"
    fi

    if [ -n "$DENY_ACCESS_DIRECTIVES" ];
    then
      echo "Deny access directives are present."
      for directive in $DENY_ACCESS_DIRECTIVES;
      do
        validateAllowDenyAccessDirective "$directive"
        echo "Adding custom deny access directive: $directive"
        parsedDirective=$(echo "$directive" | sed 's/\//\\\//g')
        allowDenyAccessDirectives="${allowDenyAccessDirectives}    deny ${parsedDirective};\n"
      done
    fi

    if [ -n "$ALLOW_ACCESS_DIRECTIVES" ];
    then
      echo "Allow access directives are present."
      for directive in $ALLOW_ACCESS_DIRECTIVES;
      do
        validateAllowDenyAccessDirective "$directive"
        echo "Adding custom allow access directive: $directive"
        parsedDirective=$(echo "$directive" | sed 's/\//\\\//g')
        allowDenyAccessDirectives="${allowDenyAccessDirectives}    allow ${parsedDirective};\n"
      done

      # Creating allow access directives (whitelist) will imply denial of access.
      allowDenyAccessDirectives="${allowDenyAccessDirectives}    deny all;\n"
    fi
  else
    # Neither allow nor deny access directives are defined, so omit configuration.
    allowDenyAccessDirectives="# Allow and deny access directives are not configured."
  fi
}

manageCustomSettings(){

  # Configure webserver to use the custom certificate and key pair.
  if [ -f $secretsMountPath/WEBSERVER_CUSTOM_CERT_FILE ] && [ -f $secretsMountPath/WEBSERVER_CUSTOM_KEY_FILE ]; then
    echo "Custom webserver cert and key found"
    certPath="${secretsMountPath}/WEBSERVER_CUSTOM_CERT_FILE"
    keyPath="${secretsMountPath}/WEBSERVER_CUSTOM_KEY_FILE"

    echo "Using $certPath and $keyPath for webserver"

    manageRootCertificate
  else
    echo "Custom webserver cert and/or key not found in ${secretsMountPath}. Generating self-signed certs to use for SSL connection"
    createSelfSignedServerCert
  fi


  # Configure to enable/disable the authentication with certificate.
  customCaComment=""
  if [ -f $secretsMountPath/AUTH_CUSTOM_CA ]; then
    echo "Custom CA for authentication found. Certificate Authentication is enabled."
  else
    echo "Custom CA cert not found in ${secretsMountPath}. Certificate Authentication is disabled."
    customCaComment="# "
  fi
}

manageCustomSettings
createBlackduckSystemClientCertificate

ipv6Comment=""
if [ -n "$IPV4_ONLY" ] && [ "$IPV4_ONLY" -eq "1" ];
then
  echo "Removing IPv6 listening."
  ipv6Comment="# "
else
  echo "Keeping IPv6 listening."
fi

manageAllowDenyAccessDirectives

docSslVerify="on"
if [ -n "$DOC_SSL_VERIFY" ] && [ "$DOC_SSL_VERIFY" -eq "0" ];
then
  echo "Disabling SSL Verify for doc server."
  docSslVerify="off"
fi

if [ -z "$(pidof .$WEBSERVER_HOME/filebeat/filebeat)"];
then
    echo "Attempting to start "$(.$WEBSERVER_HOME/filebeat/filebeat --version)
    .$WEBSERVER_HOME/filebeat/filebeat -c $WEBSERVER_HOME/filebeat/filebeat.yml start &
fi

echo "Attempting to start logrotate via background script "
/opt/blackduck/hub/webserver/bin/logrotate.sh &

echo "Attempting to start webserver."
set -e

certPath_esc=$(echo "$certPath" | sed 's/\//\\\//g')
keyPath_esc=$(echo "$keyPath" | sed 's/\//\\\//g')
rootCertPath_esc=$(echo "$rootCertPath" | sed 's/\//\\\//g')

alertComment=""
if [ -n "$USE_ALERT" ] && [ "$USE_ALERT" -eq "1" ];
then
  echo "Enabling alert rules."
  targetAlertHost="${HUB_ALERT_HOST:-alert}"
  targetAlertPort="${HUB_ALERT_PORT:-8443}"
  echo "Alert host: $targetAlertHost"
  echo "Alert port: $targetAlertPort"
  cat /etc/nginx/alert.nginx.conf.template | sed 's/${HUB_ALERT_HOST}/'"$targetAlertHost"'/g' | sed 's/${HUB_ALERT_PORT}/'"$targetAlertPort"'/g' > /etc/nginx/alert.nginx.conf
else
  echo "Disabling alert rules."
  alertComment="# "
fi

# This sets the host and port variable in proxy_pass for configuration.

# Replace each variables in the template with either the default value or specified from an orchestration tool.
cat /etc/nginx/nginx.conf.template | sed 's/${HUB_WEBSERVER_PORT}/'"$targetWebserverPort"'/g' \
| sed 's/${PUBLIC_HUB_WEBSERVER_PORT}/'"$publicWebserverPort"'/g' \
| sed 's/${HUB_WEBAPP_HOST}/'"$targetWebAppHost"'/g' | sed 's/${HUB_WEBAPP_PORT}/'"$targetWebAppPort"'/g' \
| sed 's/${HUB_DOC_HOST}/'"$targetDocHost"'/g' | sed 's/${HUB_DOC_PORT}/'"$targetDocPort"'/g' \
| sed 's/${HUB_JOBRUNNER_HOST}/'"$targetJobrunnerHost"'/g' | sed 's/${HUB_JOBRUNNER_PORT}/'"$targetJobrunnerPort"'/g' \
| sed 's/${HUB_SCAN_HOST}/'"$targetScanHost"'/g' | sed 's/${HUB_SCAN_PORT}/'"$targetScanPort"'/g' \
| sed 's/${WEBSERVER_CERT_NAME}/'"$certName"'/g' | sed 's~${WEBSERVER_CERT}~'"$certPath_esc"'~g' \
| sed 's/${TLS_PROTOCOLS}/'"$sslProtocols"'/g' \
| sed 's~${WEBSERVER_KEY}~'"$keyPath_esc"'~g' \
| sed 's~${CLIENT_CERT_PATH}~'"${WEBSERVER_HOME}/security/blackduck_system.crt"'~g' \
| sed 's~${CLIENT_KEY_PATH}~'"${WEBSERVER_HOME}/security/blackduck_system.key"'~g' \
| sed 's/${NO_IPV6}/'"$ipv6Comment"'/g' \
| sed 's/${NO_CUSTOM_CA}/'"$customCaComment"'/g' \
| sed 's~${AUTH_CUSTOM_CA}~'"${secretsMountPath}/AUTH_CUSTOM_CA"'~g' \
| sed 's/${NO_ALERT}/'"$alertComment"'/g' \
| sed 's/${ALLOW_DENY_ACCESS_DIRECTIVES}/'"$allowDenyAccessDirectives"'/g' \
| sed 's/${NO_BINARY_UPLOADS}/'"$binaryUploadComment"'/g' \
| sed 's/${DOC_SSL_VERIFY}/'"$docSslVerify"'/g' \
| sed 's/${HUB_REQUEST_HEADER_SIZE}/'"$requestHeaderSize"'/g' \
| sed 's~${WEBSERVER_ROOT_CERT_PATH}~'"$rootCertPath_esc"'~g' > /etc/nginx/nginx.conf


if [ "$exposeMetricsExternally" == "true" ];
then
    echo "Metrics are exposed externally"
    sed -i 's/#hide_metrics//g' /etc/nginx/nginx.conf
else
    echo "Metrics are not exposed externally"
fi



cat /etc/nginx/authentication.nginx.conf.template | sed 's/${HUB_AUTHENTICATION_HOST}/'"$targetAuthenticationHost"'/g' | sed 's/${HUB_AUTHENTICATION_PORT}/'"$targetAuthenticationPort"'/g' > /etc/nginx/authentication.nginx.conf

cat /etc/nginx/scan.nginx.conf.template | sed 's/${HUB_SCAN_HOST}/'"$targetScanHost"'/g' | sed 's/${HUB_SCAN_PORT}/'"$targetScanPort"'/g' > /etc/nginx/scan.nginx.conf

# Configure to enable/disable binary uploads.
echo "Enabling upload cache service rules."
targetUploadCacheHost="${HUB_UPLOAD_CACHE_HOST:-uploadcache}"
targetUploadCachePort="${HUB_UPLOAD_CACHE_PORT:-9443}"
binaryUploadMaxSize="${BINARY_UPLOAD_MAX_SIZE:-6144m}"
echo "UploadCache host: $targetUploadCacheHost"
echo "UploadCache port: $targetUploadCachePort"
cat /etc/nginx/upload.nginx.conf.template | sed 's/${HUB_UPLOAD_CACHE_HOST}/'"$targetUploadCacheHost"'/g' \
| sed 's/${HUB_UPLOAD_CACHE_PORT}/'"$targetUploadCachePort"'/g' \
| sed 's/${BINARY_UPLOAD_MAX_SIZE}/'"$binaryUploadMaxSize"'/g'> /etc/nginx/upload.nginx.conf


# Check if we are trying to run 'webserver' as 'root'
if [ "$(id -u)" = '0' ]; then
	  chown nginx:root $WEBSERVER_HOME/security/*
    set -- su-exec nginx:root "$@"
fi

exec "$@" nginx -g "daemon off;"

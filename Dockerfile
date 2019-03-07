FROM blackducksoftware/hub-docker-common:1.0.5 as docker-common
FROM nginx:1.13.6-alpine

ARG VERSION
ARG LASTCOMMIT
ARG BUILDTIME
ARG BUILD

LABEL com.blackducksoftware.hub.vendor="Black Duck Software, Inc." \
      com.blackducksoftware.hub.version="$VERSION" \
      com.blackducksoftware.hub.lastCommit="$LASTCOMMIT" \
      com.blackducksoftware.hub.buildTime="$BUILDTIME" \
      com.blackducksoftware.hub.build="$BUILD" \
      com.blackducksoftware.hub.image="webserver"

ENV BLACKDUCK_RELEASE_INFO "com.blackducksoftware.hub.vendor=Black Duck Software, Inc. \
com.blackducksoftware.hub.version=$VERSION \
com.blackducksoftware.hub.lastCommit=$LASTCOMMIT \
com.blackducksoftware.hub.buildTime=$BUILDTIME \
com.blackducksoftware.hub.build=$BUILD"

RUN echo -e "$BLACKDUCK_RELEASE_INFO" > /etc/blackduckrelease

ENV WEBSERVER_HOME="/opt/blackduck/hub/webserver"
ENV FILEBEAT_VERSION 5.5.2

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --from=docker-common healthcheck.sh /usr/local/bin/docker-healthcheck.sh

RUN set -e \
    && apk add --no-cache --virtual .hub-nginx-run-deps \
    		curl \
    		jq \
    		openssl \
    		su-exec \
    		tzdata \
    		logrotate \
    && mkdir -p $WEBSERVER_HOME/bin $WEBSERVER_HOME/security $WEBSERVER_HOME/logrotate \
	&& rm "/etc/nginx/conf.d/default.conf" "/usr/bin/nc" "/var/log/nginx/error.log" "/var/log/nginx/access.log" \
    && chmod -R g+w $WEBSERVER_HOME \
    && chgrp -R 0 "/var/cache/nginx/" \
    && chmod -R 775 "/var/log/nginx" "/var/cache/nginx/" "/var/run" "/etc/nginx" \
    && chown nginx:root $WEBSERVER_HOME/logrotate \
    && chmod 0775 $WEBSERVER_HOME/logrotate \
    && curl -L https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-$FILEBEAT_VERSION-linux-x86_64.tar.gz | \
 	   tar xz -C $WEBSERVER_HOME \
	&& mv $WEBSERVER_HOME/filebeat-$FILEBEAT_VERSION-linux-x86_64 $WEBSERVER_HOME/filebeat \
	&& chmod g+wx $WEBSERVER_HOME/filebeat
	
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY authentication.nginx.conf.template /etc/nginx/authentication.nginx.conf.template
COPY scan.nginx.conf.template /etc/nginx/scan.nginx.conf.template
COPY alert.nginx.conf.template /etc/nginx/alert.nginx.conf.template
COPY upload.nginx.conf.template /etc/nginx/upload.nginx.conf.template
COPY --from=docker-common certificate-manager.sh $WEBSERVER_HOME/bin/certmanager.sh
COPY error.html $WEBSERVER_HOME/html/
COPY filebeat.yml $WEBSERVER_HOME/filebeat/filebeat.yml
RUN chmod 644 $WEBSERVER_HOME/filebeat/filebeat.yml 
COPY logrotate.sh $WEBSERVER_HOME/bin
RUN chown nginx:root $WEBSERVER_HOME/bin/logrotate.sh
RUN chmod 0775 $WEBSERVER_HOME/bin/logrotate.sh
COPY logrotate.config /etc/logrotate.d/nginx

VOLUME [ "/etc/nginx/conf.d" ]

ENTRYPOINT [ "docker-entrypoint.sh" ]

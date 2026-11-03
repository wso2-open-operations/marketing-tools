# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.


# Docker context: amplify-database (no shared packages; ADR-027).
#   docker build -t amplify-database amplify-database
# Choreo Manual Task: runs once and exits, so no port.

FROM ballerina/ballerina:2201.13.3@sha256:7cba1a3bcb3314e2444aa6823d332e79882437df512de71037c4b0607d39e019 AS build
# The base image declares VOLUME /home/ballerina. Choreo's builder (buildah), like Docker's legacy builder, drops
# whatever a RUN step writes under a volume, so the build works in /build.
WORKDIR /build
COPY --chown=ballerina . amplify-database
RUN cd amplify-database && bal build

FROM eclipse-temurin:21-jre-alpine@sha256:82cf3d9ccbe1ed46252008d51b2f2329e6b9e8a2f4394c4bebefc3ea7f4b1372
RUN addgroup -g 10014 choreo && adduser -D -H -u 10014 -G choreo choreouser
WORKDIR /app
COPY --from=build /build/amplify-database/target/bin/amplify_database.jar app.jar
COPY --from=build --chown=10014:10014 /build/amplify-database/migrations migrations
COPY --from=build --chown=10014:10014 /build/amplify-database/seed seed
USER 10014
ENTRYPOINT ["java", "-jar", "/app/app.jar"]

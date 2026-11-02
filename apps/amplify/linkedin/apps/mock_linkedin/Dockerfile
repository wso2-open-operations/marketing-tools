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


# Mock LinkedIn (dev and local only, never prod). Docker context: this folder.
#   docker build -t mock-linkedin apps/amplify/linkedin/apps/mock_linkedin
# Two listeners (api 9090 = api.linkedin.com, www 9091 = www.linkedin.com). Config only through env:
# BAL_CONFIG_VAR_LISTENERHOST=0.0.0.0, BAL_CONFIG_VAR_CLIENTID / CLIENTSECRET, and BAL_CONFIG_DATA for
# the redirectUris array. No Config.toml is baked in.

FROM ballerina/ballerina:2201.13.3@sha256:7cba1a3bcb3314e2444aa6823d332e79882437df512de71037c4b0607d39e019 AS build
WORKDIR /home/ballerina
COPY --chown=ballerina . mock_linkedin
RUN cd mock_linkedin && bal build

FROM eclipse-temurin:21-jre-alpine@sha256:51ab5e3302e7141ce665ca3ea85e8b5cd648eafbc3c0c90dd79d6537684e4555
RUN addgroup -g 10014 choreo && adduser -D -H -u 10014 -G choreo choreouser
WORKDIR /app
COPY --from=build /home/ballerina/mock_linkedin/target/bin/mock_linkedin.jar app.jar
USER 10014
EXPOSE 9090 9091
ENTRYPOINT ["java", "-jar", "/app/app.jar"]

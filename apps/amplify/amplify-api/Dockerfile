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


# Docker context: apps/amplify. Choreo reads this component's descriptor from
# <docker context>/.choreo/component.yaml, so the context is unique per component (ADR-027).
#   docker build -f amplify-api/Dockerfile -t amplify-api .
# Clean checkout: the shared packages are packed and pushed to the build stage's own local repository first
# (ADR-020/021), so nothing comes from a developer's ~/.ballerina.

FROM ballerina/ballerina:2201.13.3@sha256:7cba1a3bcb3314e2444aa6823d332e79882437df512de71037c4b0607d39e019 AS build
WORKDIR /home/ballerina
COPY --chown=ballerina amplify-common amplify-common
RUN cd amplify-common && bal pack && bal push --repository=local
COPY --chown=ballerina amplify-domain amplify-domain
RUN cd amplify-domain && bal pack && bal push --repository=local
COPY --chown=ballerina amplify-api amplify-api
RUN cd amplify-api && bal build

FROM eclipse-temurin:21-jre-alpine@sha256:51ab5e3302e7141ce665ca3ea85e8b5cd648eafbc3c0c90dd79d6537684e4555
RUN addgroup -g 10014 choreo && adduser -D -H -u 10014 -G choreo choreouser
WORKDIR /app
COPY --from=build /home/ballerina/amplify-api/target/bin/amplify_api.jar app.jar
USER 10014
EXPOSE 9090
ENTRYPOINT ["java", "-jar", "/app/app.jar"]

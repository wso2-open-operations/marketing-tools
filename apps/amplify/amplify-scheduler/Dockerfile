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

# Amplify Scheduler (ADR-026): the upstream akornatskyy/scheduler image, pinned by tag and digest, run as a
# Choreo-compatible numeric UID (the upstream image runs as `nobody`). Nothing else is added: the scheduler
# is a single static binary in a scratch image and needs only DSN (secret) and port 8080.
#   docker build -t amplify-scheduler amplify-scheduler   (Docker context = this folder, ADR-027)
# Bumping the version: change tag + digest together, read the upstream changes, run scripts/it-scheduler.sh.

FROM akorn/scheduler:1.7.8@sha256:07462c0684245d5f8aaed8018e4594da3ba113d5b38bb6dffcc32403108d2cf6
USER 10014
EXPOSE 8080

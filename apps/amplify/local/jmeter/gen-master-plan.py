#!/usr/bin/env python3
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

# Writes master.jmx: one thread group per Ballerina module, all running in parallel.
# Edit the MODULES table here and regenerate. master.jmx is the output, not the source.
#
#   python3 local/jmeter/gen-master-plan.py > local/jmeter/master.jmx
#
# Thread counts are JMeter properties (-J<name>=<n>), so run.sh picks the modules by setting the others to 0.
import sys
from xml.sax.saxutils import escape

# Host and port the sampler reaches over the Compose network (amplify-jobs has no host port).
API = ("${__P(api.host,amplify-api)}", "${__P(api.port,9090)}")
JOBS = ("${__P(jobs.host,amplify-jobs)}", "${__P(jobs.port,9091)}")

# Who calls the endpoint: EMP = any signed-in employee, PO = amplify_po (dev token minted by run.sh).
EMP = "EMP"
PO = "PO"


def s(label, method, path, target, token=None, codes=(200,), headers=()):
    return dict(label=label, method=method, path=path, target=target, token=token, codes=codes, headers=headers)


# Thread group per module. `threads` is the JMeter property that sets its concurrency (0 = off).
MODULES = [
    dict(group="api", threads="api.threads", default=10, samplers=[
        s("api/ready", "GET", "/ready", API),
        s("api/me", "GET", "/me", API, EMP),
        s("api/me-points", "GET", "/me/points", API, EMP),
        s("api/me-shares", "GET", "/me/shares", API, EMP),
        s("api/campaigns", "GET", "/campaigns?status=open", API, EMP),
        s("api/leaderboard", "GET", "/leaderboard?period=ALL", API, EMP),
        s("api/tags", "GET", "/tags", API, EMP),
        s("api/categories", "GET", "/categories", API, EMP),
    ]),
    # amplify-domain is a library: no endpoint of its own. These are the API reads that run its
    # repositories (team and PO views, point rules, external-share queue), so its numbers come from them.
    dict(group="domain", threads="domain.threads", default=10, samplers=[
        s("domain/team", "GET", "/team?page=${__Random(0,39,)}&sort=rank", API, PO),
        s("domain/team-history", "GET", "/team/${EMP_ID}/history?page=0&size=25", API, PO),
        s("domain/po-dashboard", "GET", "/po/dashboard", API, PO),
        s("domain/po-point-rules", "GET", "/po/point-rules", API, PO),
        s("domain/po-external-shares", "GET", "/po/external-shares?status=PENDING&page=0", API, PO),
    ]),
    # amplify-common is a library too. Reached through the shared edges: health probe, the auth
    # rejection path and the problem-details envelope for unknown resources.
    dict(group="common", threads="common.threads", default=2, samplers=[
        s("common/health", "GET", "/health", API),
        s("common/unauthenticated", "GET", "/me", API, codes=(401,)),
        # A well-formed id that matches nothing: 404 problem details. (A malformed id is 400, per openapi.yaml.)
        s("common/problem-not-found", "GET", "/campaigns/00000000-0000-7000-8000-000000000000", API, EMP, codes=(404,)),
    ]),
    dict(group="jobs", threads="jobs.threads", default=2, samplers=[
        s("jobs/health", "GET", "/health", JOBS),
        s("jobs/ready", "GET", "/ready", JOBS),
    ]),
    # Idempotent maintenance (partition upkeep). Runs at 1 thread by default.
    dict(group="jobs-maintenance", threads="jobs.maintenance.threads", default=1, samplers=[
        s("jobs/partitions", "POST", "/maintenance/partitions", JOBS, codes=(200, 201, 202, 204)),
    ]),
    # Opt-in (RUN_JOBS=1 in run.sh): drains the outbox, so it posts to LinkedIn and chat-stub.
    dict(group="jobs-run", threads="jobs.run.threads", default=0, samplers=[
        s("jobs/runs", "POST", "/runs", JOBS, codes=(200, 202),
          headers=(("X-Correlation-ID", "${__UUID()}"),)),
    ]),
]


def string_prop(name, value):
    return f'<stringProp name="{name}">{escape(value)}</stringProp>'


def bool_prop(name, value):
    return f'<boolProp name="{name}">{"true" if value else "false"}</boolProp>'


def csv_data_set(name, file_prop, default_file, variables):
    return f'''<CSVDataSet guiclass="TestBeanGUI" testclass="CSVDataSet" testname="{name}" enabled="true">
{string_prop("filename", "${__P(" + file_prop + "," + default_file + ")}")}
{string_prop("fileEncoding", "UTF-8")}
{string_prop("variableNames", variables)}
{bool_prop("ignoreFirstLine", False)}
{string_prop("delimiter", ",")}
{bool_prop("quotedData", False)}
{bool_prop("recycle", True)}
{bool_prop("stopThread", False)}
{string_prop("shareMode", "shareMode.all")}
</CSVDataSet>
<hashTree/>'''


def header_manager(headers):
    rows = "".join(
        f'<elementProp name="" elementType="Header">{string_prop("Header.name", n)}{string_prop("Header.value", v)}</elementProp>'
        for n, v in headers
    )
    return f'''<HeaderManager guiclass="HeaderPanel" testclass="HeaderManager" testname="Headers" enabled="true">
<collectionProp name="HeaderManager.headers">{rows}</collectionProp>
</HeaderManager>
<hashTree/>'''


def response_assertion(codes):
    # One regex on the status code. "Ignore status" (assume_success) is on, so JMeter does not mark a
    # 4xx as failed on its own: the expected code is the contract, and only this assertion decides.
    pattern = "|".join(str(c) for c in codes)
    return f'''<ResponseAssertion guiclass="AssertionGui" testclass="ResponseAssertion" testname="Status {pattern}" enabled="true">
<collectionProp name="Asserion.test_strings"><stringProp name="49586">{pattern}</stringProp></collectionProp>
<stringProp name="Assertion.custom_message"></stringProp>
<stringProp name="Assertion.test_field">Assertion.response_code</stringProp>
<boolProp name="Assertion.assume_success">true</boolProp>
<intProp name="Assertion.test_type">1</intProp>
</ResponseAssertion>
<hashTree/>'''


def sampler(x):
    (domain, port) = x["target"]
    headers = []
    if x["token"] == EMP:
        headers.append(("x-jwt-assertion", "${EMP_TOKEN}"))
    elif x["token"] == PO:
        headers.append(("x-jwt-assertion", "${PO_TOKEN}"))
    headers.extend(x["headers"])
    header_block = f"{header_manager(headers)}\n" if headers else ""
    return f'''<HTTPSamplerProxy guiclass="HttpTestSampleGui" testclass="HTTPSamplerProxy" testname="{x["label"]}" enabled="true">
<elementProp name="HTTPsampler.Arguments" elementType="Arguments" guiclass="HTTPArgumentsPanel" testclass="Arguments" testname="User Defined Variables" enabled="true"><collectionProp name="Arguments.arguments"/></elementProp>
{string_prop("HTTPSampler.domain", domain)}
{string_prop("HTTPSampler.port", port)}
{string_prop("HTTPSampler.protocol", "http")}
{string_prop("HTTPSampler.contentEncoding", "")}
{string_prop("HTTPSampler.path", x["path"])}
{string_prop("HTTPSampler.method", x["method"])}
{bool_prop("HTTPSampler.follow_redirects", True)}
{bool_prop("HTTPSampler.auto_redirects", False)}
{bool_prop("HTTPSampler.use_keepalive", True)}
{bool_prop("HTTPSampler.DO_MULTIPART_POST", False)}
{string_prop("HTTPSampler.connect_timeout", "5000")}
{string_prop("HTTPSampler.response_timeout", "10000")}
</HTTPSamplerProxy>
<hashTree>
{header_block}{response_assertion(x["codes"])}</hashTree>'''


def thread_group(m):
    samplers = "\n".join(sampler(x) for x in m["samplers"])
    return f'''<ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="{m["group"]}" enabled="true">
{string_prop("ThreadGroup.on_sample_error", "continue")}
<elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController" testname="Loop Controller" enabled="true">
{bool_prop("LoopController.continue_forever", False)}
<intProp name="LoopController.loops">-1</intProp>
</elementProp>
{string_prop("ThreadGroup.num_threads", "${__P(" + m["threads"] + "," + str(m["default"]) + ")}")}
{string_prop("ThreadGroup.ramp_time", "${__P(ramp,30)}")}
{bool_prop("ThreadGroup.scheduler", True)}
{string_prop("ThreadGroup.duration", "${__P(duration,120)}")}
{string_prop("ThreadGroup.delay", "")}
{bool_prop("ThreadGroup.same_user_on_next_iteration", True)}
</ThreadGroup>
<hashTree>
<ConstantTimer guiclass="ConstantTimerGui" testclass="ConstantTimer" testname="Think time" enabled="true">
{string_prop("ConstantTimer.delay", "${__P(think.ms,200)}")}
</ConstantTimer>
<hashTree/>
<RandomOrderController guiclass="RandomOrderControllerGui" testclass="RandomOrderController" testname="Mix {m["group"]}" enabled="true"/>
<hashTree>
{samplers}
</hashTree>
</hashTree>'''


def plan():
    groups = "\n".join(thread_group(m) for m in MODULES)
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!-- Generated by gen-master-plan.py. Edit the generator, not this file. -->
<jmeterTestPlan version="1.2" properties="5.0" jmeter="5.5">
<hashTree>
<TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="Amplify performance: master" enabled="true">
{string_prop("TestPlan.comments", "One thread group per Ballerina module (amplify-api, amplify-domain, amplify-common, amplify-jobs). Groups run in parallel; set a group's threads to 0 to leave it out. Labels are module/endpoint, so summarize.py can split the percentiles per module.")}
{bool_prop("TestPlan.functional_mode", False)}
{bool_prop("TestPlan.serialize_threadgroups", False)}
<elementProp name="TestPlan.user_defined_variables" elementType="Arguments" guiclass="ArgumentsPanel" testclass="Arguments" testname="User Defined Variables" enabled="true"><collectionProp name="Arguments.arguments"/></elementProp>
{string_prop("TestPlan.user_define_classpath", "")}
</TestPlan>
<hashTree>
{csv_data_set("Employee tokens (EMP_TOKEN, EMP_ID)", "employees.file", "/work/employees.csv", "EMP_TOKEN,EMP_ID")}
{csv_data_set("PO token (PO_TOKEN)", "po.file", "/work/po.csv", "PO_TOKEN")}
{groups}
</hashTree>
</hashTree>
</jmeterTestPlan>
'''


if __name__ == "__main__":
    sys.stdout.write(plan())

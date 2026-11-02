// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.


// Process-wide transaction gate (round 2 item 12, R-13: docs/reviews/2026-10-17-r13-transaction-race.md).
//
// On Ballerina 2201.13.x, concurrent `transaction {}` blocks race on an unsynchronized HashMap in the
// runtime's `TransactionResourceManager` (ballerina-lang #44737, fixed by PR #44747 in 2201.14.0 only; the
// 13.x backport was closed). The race throws ConcurrentModificationException, or reports a commit that
// never happened, and leaks the pool connection for good. One process-wide lock around every transaction
// measured 0 failures and 0 leaks, so every product `transaction` block runs through `inTransaction` /
// `inTransactionValue` below (`scripts/check-transaction-gate.sh` fails the build otherwise).
//
// REMOVE after upgrading to Ballerina 2201.14.1+ (rerun the full suite and the R-13 probe first): inline
// the `work` bodies again and delete this file and the check script.
//
// Rules for the work function: keep it short (transactions now run one at a time per process), never call
// `inTransaction` from inside it, never `retry transaction` (it raised the CME rate ~15x on 13.x), and
// don't wait on anything slow while it runs (`lockRecognition` polls for at most 2 s for that reason).

# Every gated transaction locks this one variable: separate `lock` statements on different variables don't
# exclude each other. The count is only there to give the lock something to guard (and for tests).
isolated int txGate = 0;

# Runs one unit of work holding the process-wide transaction gate. `work` contains the whole
# `transaction { ...; check commit; }` block.
#
# + work - The transaction
# + return - Its error, if any
public isolated function inTransaction(isolated function () returns error? work) returns error? {
    lock {
        txGate += 1;
        return work();
    }
}

# `inTransaction` for a transaction that produces a value (a version, a row count, a flag). Callers narrow
# the result with `ensureType`.
#
# + work - The transaction
# + return - Its value, or its error
public isolated function inTransactionValue(isolated function () returns anydata|error work) returns anydata|error {
    lock {
        txGate += 1;
        return work();
    }
}

# How many gated transactions this process has run (tests).
#
# + return - Count
public isolated function gatedTransactions() returns int {
    lock {
        return txGate;
    }
}

-- Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
--
-- WSO2 LLC. licenses this file to you under the Apache License,
-- Version 2.0 (the "License"); you may not use this file except
-- in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.
-- Local prototype only: the Amplify demo cast for people-app's GET /employees/basic-info.
-- Fake cast on example.com addresses; no real people. To sign in as one of them, change the email to the one
-- your sign-in reaches Amplify with. The head_email columns are placeholders (the first member listed for that group).

INSERT INTO employment_type (id, name, created_by, updated_by) VALUES (1, 'Permanent', 'seed', 'seed');
INSERT INTO designation (id, designation, job_band, created_by, updated_by) VALUES (1, 'Engineer', 8, 'seed', 'seed');
INSERT INTO company (id, name, prefix, location, created_by, updated_by) VALUES (1, 'WSO2 - US', 'US', 'US', 'seed', 'seed');
INSERT INTO business_unit (id, name, head_email, created_by, updated_by) VALUES
  (1, 'PO', 'avery@example.com', 'seed', 'seed'),
  (2, 'SLT', 'devon@example.com', 'seed', 'seed'),
  (3, 'CS', 'emery@example.com', 'seed', 'seed'),
  (4, 'MKT', 'logan@example.com', 'seed', 'seed');
INSERT INTO team (id, name, head_email, created_by, updated_by) VALUES
  (1, 'PO', 'avery@example.com', 'seed', 'seed'),
  (2, 'SLT', 'devon@example.com', 'seed', 'seed'),
  (3, 'CS', 'emery@example.com', 'seed', 'seed'),
  (4, 'MKT', 'morgan@example.com', 'seed', 'seed');
INSERT INTO sub_team (id, name, head_email, created_by, updated_by) VALUES
  (1, 'PO', 'avery@example.com', 'seed', 'seed'),
  (2, 'CEO', 'devon@example.com', 'seed', 'seed'),
  (3, 'FDE', 'emery@example.com', 'seed', 'seed'),
  (4, 'CS', 'hayden@example.com', 'seed', 'seed'),
  (5, 'MKT', 'logan@example.com', 'seed', 'seed'),
  (6, 'TRAIN', 'nico@example.com', 'seed', 'seed');
-- Replace the default houses with the demo ones.
DELETE FROM house;
INSERT INTO house (id, name) VALUES
  (1, 'Wildbore'),
  (2, 'Orion'),
  (3, 'Pegasus'),
  (4, 'Phoenix'),
  (5, 'Centaurus');

INSERT INTO personal_info (id, nic_or_passport, first_name, last_name, title, dob, nationality, created_by, updated_by) VALUES
  (1, 'P1', 'Avery', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (2, 'P2', 'Blake', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (3, 'P3', 'Casey', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (4, 'P4', 'Devon', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (5, 'P5', 'Emery', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (6, 'P6', 'Finley', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (7, 'P7', 'Gray', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (8, 'P8', 'Hayden', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (9, 'P9', 'Jordan', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (10, 'P10', 'Kai', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (11, 'P11', 'Logan', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (12, 'P12', 'Morgan', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed'),
  (13, 'P13', 'Nico', 'Demo', 'Mx', '1990-01-01', 'US', 'seed', 'seed');

INSERT INTO employee (employee_id, first_name, last_name, work_location, work_email, employee_thumbnail, house_id, start_date, manager_email,
    employee_status, created_by, updated_by, employment_type_id, designation_id, company_id, team_id, sub_team_id,
    business_unit_id, personal_info_id) VALUES
  ('00000000-0000-4000-8000-000000000001', 'Avery', 'Demo', 'US', 'avery@example.com', '', 1, '2024-01-01', 'avery@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 1),
  ('00000000-0000-4000-8000-000000000002', 'Blake', 'Demo', 'US', 'blake@example.com', '', 2, '2024-01-01', 'avery@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 2),
  ('00000000-0000-4000-8000-000000000003', 'Casey', 'Demo', 'US', 'casey@example.com', '', 3, '2024-01-01', 'avery@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 3),
  ('00000000-0000-4000-8000-000000000004', 'Devon', 'Demo', 'US', 'devon@example.com', '', 2, '2024-01-01', 'devon@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 2, 2, 2, 4),
  ('00000000-0000-4000-8000-000000000005', 'Emery', 'Demo', 'US', 'emery@example.com', '', 1, '2024-01-01', 'emery@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 3, 3, 3, 5),
  ('00000000-0000-4000-8000-000000000006', 'Finley', 'Demo', 'US', 'finley@example.com', '', 1, '2024-01-01', 'avery@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 6),
  ('00000000-0000-4000-8000-000000000007', 'Gray', 'Demo', 'US', 'gray@example.com', '', 3, '2024-01-01', 'emery@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 3, 3, 3, 7),
  ('00000000-0000-4000-8000-000000000008', 'Hayden', 'Demo', 'US', 'hayden@example.com', '', 2, '2024-01-01', 'hayden@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 2, 4, 3, 8),
  ('00000000-0000-4000-8000-000000000009', 'Jordan', 'Demo', 'US', 'jordan@example.com', '', 1, '2024-01-01', 'emery@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 3, 3, 3, 9),
  ('00000000-0000-4000-8000-000000000010', 'Kai', 'Demo', 'US', 'kai@example.com', '', 2, '2024-01-01', 'avery@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 1, 1, 1, 10),
  ('00000000-0000-4000-8000-000000000011', 'Logan', 'Demo', 'US', 'logan@example.com', '', 3, '2024-01-01', 'logan@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 2, 5, 4, 11),
  ('00000000-0000-4000-8000-000000000012', 'Morgan', 'Demo', 'US', 'morgan@example.com', '', 3, '2024-01-01', 'logan@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 4, 5, 4, 12),
  ('00000000-0000-4000-8000-000000000013', 'Nico', 'Demo', 'US', 'nico@example.com', '', 3, '2024-01-01', 'nico@example.com', 'Active', 'seed', 'seed', 1, 1, 1, 4, 6, 4, 13);

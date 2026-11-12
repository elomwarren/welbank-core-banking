# database/seed/

Synthetic data for development and demonstrations: a bank with about 2,000 customers, 160 employees in 21 branches across Ghana's 16 regions, and two years of activity, shaped by the 2021 Population and Housing Census. Every person is fictional; e-mail addresses use the reserved `example.com` domain.

```text
seed/
├── generate_seed.py   Python (standard library only): writes build/seed.sql
├── data/              Inputs, with their sources (below)
├── sql/
│   ├── preflight.sql       refuses a database that already has customers
│   ├── simulate_month.sql  one month of activity, through the packages
│   └── finish.sql          end of day to today, KYC reviews, cards, checks, summary
└── build/             Generated (git-ignored): seed.sql
```

## Running it

```bash
./scripts/db-seed.sh                          # default: 2,000 customers, 24 months
./scripts/db-seed.sh --customers 300 --months 6
```

It runs on an **empty** database only (no customers yet). The default load (2,000 customers, 24 months) takes about 90 minutes; `--customers 150 --months 4` takes about 15 seconds. The audit trail is an immutable table, so a seeded database cannot be emptied again; to start over, recreate the database (`docker compose down -v`, `docker compose up -d`, then `db-migrate.sh update`).

## How it works

- `generate_seed.py` writes reference data (currencies, countries, regions, branches, departments, jobs, limits, products, Bank of Ghana loan classes, the branches' own accounts) and the staff as plain inserts: those tables have no package.
- Customers are onboarded month by month **through the packages**, played by the right employees (customer service registers and captures, the branch manager approves): registration, address, contacts, next of kin, a generated photo and signature, the (simulated) NIA verification, sanctions screening, KYC approval, account opening and approval. About 3 % fail their NIA check (deferred, deposits only; two in three come back and are verified later), 1 % are not verified yet, a few wait on a sanctions match.
- Each month `simulate_month.sql` posts deposits, withdrawals and transfers through `pkg_posting` (over-limit amounts go to the teller supervisor), grants and services loans through `pkg_loan` (85 % repay on time, 10 % late, 5 % stop paying, so arrears and Bank of Ghana classes appear), and runs the loans' end of day.
- Rows are created at load time and then **back-dated** into their simulated month (transactions, ledger lines, customers, accounts, loans, approvals). The audit trail is not back-dated: it truthfully shows when the seed was loaded.
- `DBMS_RANDOM` is seeded per month and Python uses a fixed seed: the same arguments give the same data.
- The v1 staff (42) and customers (60) are kept; v1 balances are paid in as opening deposits.

## Sources

| File | Content | Source |
|---|---|---|
| `census_2021_adults_by_age_sex.csv` | Population by single year of age (18 to 95+) and sex | Ghana Statistical Service, 2021 PHC General Report Vol. 3B, Table 5.1 |
| `census_2021_regions.csv` | Population of the 16 regions, by sex | GSS, 2021 PHC General Report Vol. 3C, Table 5.1 |
| `census_2021_ethnicity_by_region.csv` | Ghanaians by major ethnic group and region | GSS, 2021 PHC General Report Vol. 3C, Table 5.5 |
| `census_2021_non_ghanaians.csv` | Non-Ghanaians by nationality (ECOWAS countries, other continents) | GSS, 2021 PHC General Report Vol. 3C, Table 5.1 |
| `v1_*.csv` | Departments, jobs, employees, customers, accounts of WEL Bank v1 | `legacy/desktop-pyqt6/sql/SQLScript2_Data_Input.sql` |

Totals check against the census: 30,832,019 people; 270,838 ECOWAS nationals; 294,341 non-Ghanaians (294,234 plus 107 stateless). Names, occupations, incomes, account and loan behaviour are illustrative choices, not census data. Non-Ghanaians are slightly over-represented (at least 40 customers, about 2 %, against 0.9 % in the census) so that every nationality group appears.

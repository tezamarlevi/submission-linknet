# LinkNet Data Analyst & Visualization Assessment

This submission analyzes the five supplied infrastructure, subscription, Servco, region, and media CSV files for January to December 2025. It addresses network utilization, partner performance, media monetization, and the next six months of business priorities.

## Deliverables

| File | Purpose |
| --- | --- |
| [`sql/analysis.sql`](sql/analysis.sql) | 21 independent PostgreSQL queries covering the four assessment sections. |
| [`sql/tableau_exports.sql`](sql/tableau_exports.sql) | Six SQL queries (T01-T06) for producing dashboard-level aggregates. |
| [`tableau/data/`](tableau/data/) | Six aggregate CSVs prepared directly from the supplied source files for Tableau. These are source-based reproductions, not exports from a PostgreSQL run. |
| [`Linknet Executive Summary.pdf`](Linknet%20Executive%20Summary.pdf) | Two-page, business-focused executive summary. The current PDF still contains a draft note about the Tableau link. |
| [`business-understanding.md`](business-understanding.md) | Detailed findings, metric definitions, assumptions, scenarios, and limitations. |

**Tableau Public dashboard:** [LinkNet FiberCo Performance & Monetization 2025](https://public.tableau.com/views/LinkNetFiberCoPerformanceMonetization2025/Dashboard1?:language=en-US&publish=yes&:sid=&:redirect=auth&:display_count=n&:origin=viz_share_link)

## How I worked

1. **Understood the data and the questions.** I inspected all five CSV files, their row-level grain, keys, date coverage, and relationships. I mapped each assessment question to a measure or comparison before writing the analysis.
2. **Defined measures that avoid double counting.** I treated an active contract account (CA) as the unit for lease and media analysis, while counting serviceable homepasses once for infrastructure denominators and CAPEX. Monthly penetration is active CAs divided by built homepasses; occupied homepasses are reported separately because a home may have more than one active CA.
3. **Checked the source data independently.** I audited uniqueness, key relationships, status consistency, monthly coverage, and headline totals directly from the CSVs. The source-based audit was rerun and matched its saved result. I then prepared 21 self-contained PostgreSQL queries for infrastructure, Servco competition, media economics, and strategic scenarios. The SQL uses the imported schema name `linknet_assesment`.
4. **Prepared the visualization inputs.** I created six aggregate CSVs at distinct grains, including monthly portfolio, segment, node, Servco, December media product, and same-region node benchmark. These files contain no raw `homeid` or `contract_account` identifiers. `sql/tableau_exports.sql` provides the corresponding SQL export queries. The Tableau Public dashboard is linked above.
5. **Translated analysis into decisions.** I compared the five formerly exclusive nodes with never-exclusive nodes in the same regions, tested 25%, 50%, and 100% closure of the observed gap, and separated this arithmetic scenario from a forecast or causal claim. I summarized the resulting priorities, evidence, and risks in the PDF and the supporting business-understanding document.

## Key assumptions and limits

- All 1,000 homepasses are used as the 2025 infrastructure denominator because they were built before 2025. However, 169 formerly exclusive homes have no snapshot rows before July. Missing rows are not treated as confirmed inactive service.
- `exclusive_flag` identifies a historical cohort. The recorded exclusive window ends on 30 June 2025; later comparisons require this time distinction.
- Lease and media values use listed fees and prices as proxies. Actual invoices, billing frequency, currency, media effective dates, and full CATV costs are unavailable, so the analysis does not claim verified billed revenue, customer ARPU, or full contribution margin.
- The XLS minimum-guarantee value of `0.25` is evaluated only as an explicitly labeled scenario because the contract denominator and settlement rules were not supplied.
- The same-region peer gap is an arithmetic benchmark. It does not prove that exclusivity caused the difference or predict how many customers a policy change will add.

## Reproduce and review

Import the five supplied semicolon-delimited CSVs into PostgreSQL under the schema `linknet_assesment`, preserving dates, numeric fields, and blank values. Run any numbered query in `sql/analysis.sql` independently. The prepared Tableau CSVs were generated from the original CSV files and reconciled against the independent source audit; the SQL export queries have not been verified against the imported PostgreSQL tables in this package.

Before submitting, verify that the dashboard opens without signing in and update `Linknet Executive Summary.pdf` so it contains the working Tableau Public URL and no draft note.

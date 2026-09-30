# Data and Business Understanding

**Decision brief, based on the five supplied CSV files.** The network grew from 333 active contract accounts (CAs) in January to 769 in December 2025. The listed-fee lease proxy rose from 44,074,000 to 101,267,000 source units. Growth is real within the supplied snapshots, but the next decision is about where to sell capacity already built: the five formerly exclusive nodes are the five least penetrated nodes in December, while broad FTTH expansion is not supported by the utilization pattern alone.

The most useful next-six-month move is a measured activation campaign on those five nodes, with multiple Servcos and a specific node-level target. Matching never-exclusive nodes **in the same regions** is an arithmetic scenario of **52 more CAs and 6,824,995 additional listed-fee lease units per month**. It represents 6.74% of December's lease proxy. It is a benchmark, not a causal estimate or a revenue forecast. The proposed first-stage target is one-quarter to one-half of that gap: 13 to 26 CAs and roughly 1.71 million to 3.41 million monthly lease units, subject to validating actual access, demand, and billing.

## 1. The portfolio grew, but homepasses and accounts tell different stories

| Month-end | Observed homepasses in snapshots | Active CAs | Occupied homepasses | CA / 1,000 homepasses | Lease proxy | Media-attached active CAs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| January 2025 | 831 | 333 | 319 | 33.3% | 44,074,000 | 156 |
| June 2025 | 831 | 576 | 535 | 57.6% | 76,176,000 | 278 |
| July 2025 | 1,000 | 636 | 583 | 63.6% | 84,032,000 | 303 |
| December 2025 | 1,000 | 769 | 696 | 76.9% | 101,267,000 | 360 |

The assessment's penetration measure is **active CAs divided by serviceable homepasses**. It is account density, not the share of households connected: in December, 769 active CAs occupied 696 distinct homes. The denominator holds all 1,000 built homepasses throughout 2025 because all were built before that year. However, 169 formerly exclusive homepasses have no snapshot records before July. We cannot treat those missing rows as confirmed inactive service. The July step in coverage is central to interpreting every before-and-after result. The December total is also 14 CAs below November's 783, so the year-end run rate should not be presented as uninterrupted growth.

**Infrastructure efficiency.** December FTTH density was 540/719 homepasses, or 75.10%, versus 229/281, or 81.49%, for HFC. FTTH trailed HFC within 14 of the 20 mixed-technology nodes. Technology assignment is not random, so this is not proof that HFC causes higher conversion. It does remove the simplest case for expanding FTTH everywhere immediately. Jakarta Selatan is the clearest regional utilization problem: it has the highest recorded CAPEX, 833,327,370, and the lowest regional CA density, 98/150 or 65.33%. Its former-exclusive node `F708541` has just 22 CAs on 50 homepasses and approximately 12.47 million of recorded CAPEX per active CA. This stock-CAPEX ratio is a utilization diagnostic, not customer acquisition cost or an investment return.

SQL evidence: Q02 and Q03 produce monthly portfolio and region/technology/exclusivity slices; Q04 to Q06 rank nodes, compare regional CAPEX efficiency, and pair FTTH with HFC inside nodes.

## 2. Servco growth and exclusivity need a cohort-aware reading

| Servco | Active CAs, Jan to Dec | Dec share of lease proxy | Dec CAs / all homepasses | Dec media attach |
| --- | ---: | ---: | ---: | ---: |
| XLS | 87 to 175 | 24.19% | 17.5% | 46.86% |
| MMA | 79 to 162 | 20.80% | 16.2% | 51.85% |
| SURGE | 48 to 157 | 19.38% | 15.7% | 48.41% |
| TETRA | 63 to 149 | 18.83% | 14.9% | 40.94% |
| INFOCOM | 56 to 126 | 16.80% | 12.6% | 45.24% |

SQL evidence for this exact comparison: **Q21** in `submission/sql/analysis.sql`. Q07 provides the full monthly Servco series, and Q12 provides more December media detail.

XLS remains the largest contributor, with 175 December CAs and 24,500,000 lease-proxy units. The density column is a **portfolio share**, not the fraction of homepasses a Servco could contractually access. Q07 also shows a modeled accessible denominator: during the recorded exclusive window, it excludes XLS-only homes for the other Servcos; after the window, it includes all homes. Actual partner access rights were not supplied.

The XLS `minimum_guarantee` entry is `0,25`. If, purely as a scenario, it means 25% of all 250 exclusive-cohort homepasses by June, the target would be `CEIL(250 × 0.25) = 63` CAs. XLS had 60 CAs on that cohort at 30 June, a scenario gap of three. Only 81 of the 250 homes had any June snapshot, and the contract's eligible denominator, measurement period, and settlement rule are missing. This **does not establish a guarantee breach**. Q08 makes both the full-cohort and observed-subset denominators explicit.

During June, each of the five exclusive nodes had one Servco with an active CA, while each of the 15 never-exclusive nodes had five. By December, all 20 nodes had five active Servcos. This describes observed service, not permission or the effect of changing access policy. The former-exclusive cohort rose from 60 June CAs, all XLS, to 149 December CAs, 57 XLS and 92 other-Servco. Yet the 81 exclusive-cohort homes observed in **all 12 months** went from 60 to only 65 CAs. The other 84 of the full-cohort increase are on homes first seen from July; their June service state is unknown. Q09 to Q11 and Q19 expose this coverage change alongside the competition labels.

## 3. Deep dive: a peer benchmark for five existing nodes

In December, former-exclusive homepasses had **149/250 = 59.6%** CA density versus **620/750 = 82.67%** for never-exclusive homepasses. All five former-exclusive nodes occupy the bottom five positions in the 20-node penetration ranking. The more conservative comparison is with never-exclusive nodes inside each node's own region:

| Former-exclusive node | Region | Actual CAs / 50 HP | Regional peer CAs / HP | Scenario CA gap | Scenario monthly lease gap |
| --- | --- | ---: | ---: | ---: | ---: |
| `F708541` | Jakarta Selatan | 22 / 50 | 76 / 100 | 16 | 2,093,053 |
| `F926002` | Jakarta Utara | 33 / 50 | 89 / 100 | 11.5 | 1,515,287 |
| `F951618` | Jakarta Pusat | 31 / 50 | 40 / 50 | 9 | 1,183,725 |
| `F125728` | Jakarta Timur | 31 / 50 | 78 / 100 | 8 | 1,050,051 |
| `F737809` | Jakarta Barat | 32 / 50 | 79 / 100 | 7.5 | 982,880 |
| **Total**  | |                     **149 / 250** | | **52** | **6,824,995** |

For each row, the CA gap is `MAX(0, node HP × same-region peer CA / peer HP − node CA)`. The lease gap applies the peer region's December listed-fee lease per active CA. The total is rounded **after** summing unrounded node values; individually rounded rows differ by one unit. Fractional CAs are useful for an aggregate scenario but cannot be literal customer targets. Q17 and Q18 reproduce the detail and 25%, 50%, and 100% sensitivity cases.

The strongest single target is `F708541`: 44% density versus 76% at its same-region peers, implying 16 of the 52 benchmark CAs. `F737809` merits a second look because its recorded node CAPEX is 287,817,281, the highest of the five former-exclusive nodes, but its density is 64%. The analysis cannot attribute these gaps to exclusivity. Demand, distribution, service quality, and the first-half snapshot gap are unmeasured.

## 4. Media adds listed value, but its full contribution is unknown

At December month-end, **360 of 769 active CAs (46.81%)** have a media record. Their CATV listed prices total 32,130,000, and add-on RRP totals 19,334,000, making the media gross-price proxy 51,464,000. This is about 50.8% of the 101,267,000 lease proxy. The observed add-on `RRP − wholesale` difference totals **8,129,000**, or about 22,581 per attached CA. It is not full MediaCo contribution margin: CATV cost, discounts, operating cost, actual charges, and effective dates are absent.

**Product choice.** Catchplay has the largest observed unit difference (30,000) and the highest December total add-on margin proxy (2,370,000 across 79 attached CAs). Sport Pack is next by total (1,943,000 across 67). News Pack has 85 attached CAs but only 9,000 unit difference, yielding 765,000 total. This supports testing a more profitable offer mix, subject to take-up and customer value, rather than removing a popular lower-margin product based only on unit margin.

**Upsell distribution.** MMA leads on attach rate, 84/162 or 51.85%, and on attached count and observed add-on margin, 1,891,000. TETRA is lowest on attach rate, 61/149 or 40.94%. At the region level, Jakarta Utara has 122 active CAs but just 48 media attachments (39.34%). Holding the active-CA base fixed and moving each below-average region to the December portfolio attach rate produces about **12.86 additional attached CAs and 290,581 more add-on-margin proxy units** across Jakarta Utara, Jakarta Barat, and Tangerang. Jakarta Utara accounts for about 9.11 attachments and 205,780 units. This is a small, testable scenario beside the node lease gap, not a sales forecast. Q12 to Q16 and Q20 expose the partner, region, product, monthly bridge, and scenario calculations.

**ARPU question.** The combined listed-value proxy is `(lease + CATV price + add-on RRP) / active CA`: 198,610 in December versus 195,544 in January, a 1.57% rise. The attach proxy was essentially flat, 46.85% in January and 46.81% in December. Media clearly adds **listed gross value** in this model, but these files cannot show whether bundling meaningfully increased **actual customer ARPU** or full contribution margin. The media file is undated, and FiberCo lease fees and MediaCo list prices are not a single customer bill.

## Six-month decision sequence

1. **Sell capacity on the five former-exclusive nodes first.** Prioritize `F708541`, then inspect `F737809` and the other three nodes. Give each Servco a node-level lead and conversion target, and measure active CAs, occupied homes, and realized lease invoices monthly. A 25%-50% closure of the regional peer gap corresponds to about 13-26 CAs and 1.71-3.41 million monthly lease-proxy units. Start with an eligibility, demand, and quality check before promising that outcome.
2. **Use a controlled multi-Servco access pilot and make future exclusivity conditional.** Do not renew or expand exclusivity automatically based on the raw pre/post comparison. The five nodes changed from one active ISP each in June to five each in December, but 169 homes also entered snapshot coverage in July. Confirm contractual access rights and compare like-for-like observed homes or matched nodes while recording leads, service quality, and actual invoices. Review XLS guarantee terms with the contract owner before any compliance judgment.
3. **Test higher-margin media attachment where the denominator is clear.** Begin with Jakarta Utara and TETRA, using MMA's 51.85% attach as an internal sales-process reference. Track offer exposure, attach, actual billed revenue, and CATV plus add-on costs. Catchplay is the best observed add-on by unit and total margin proxy, but test take-up before changing the package mix. The region-to-portfolio attach scenario is only about 0.29 million add-on-margin units monthly, so it complements rather than replaces the infrastructure focus.

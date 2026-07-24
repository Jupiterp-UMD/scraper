# Jupiterp grade data

Loads UMD grade distribution files, obtained by MPIA request, into Supabase so
the API can serve them.

The Registrar sends one file per term, by email, whenever a request is fulfilled.
This loader turns those files into rows and is built so that adding the next one
is a single command.

It lives in the scraper repo, at `scraper/grades/`, because it shares the
scraper's `DATABASE_URL`/`DATABASE_KEY` + `supabase-py` conventions but is
otherwise self-contained (its own `main.py`, `db.py`, and `requirements.txt`).
It does not import the scraper, and the scraper does not import it. **Run every
command below from this `grades/` directory** (`cd grades` first).

## Setup

```
python3 -m pip install -r requirements.txt
psql "$DATABASE_URL" -f schema.sql        # once
```

`DATABASE_URL` and `DATABASE_KEY` are read from the environment or a `.env`
file, exactly as in the scraper. The key must be the service role key: the
`grades` table is readable by anyone but writable only by that role.

## Usage

```
# load everything the Registrar has sent so far
python3 main.py ingest --dir ./data

# load one new term
python3 main.py ingest "./data/UMCP grade distribution Fall 2026.csv"

# check a file parses, without a database or credentials
python3 main.py verify ./data/whatever.csv

# dump normalized rows to CSV instead of uploading
python3 main.py ingest --dir ./data --out grades.csv

# what is loaded right now
python3 main.py terms
```

Useful flags: `--term 202608` to override term detection, `--force` to reload a
file already logged, `--replace-term` to clear a term before loading (only
needed when a corrected file has *fewer* rows than the one it replaces), and
`--print-output` to parse and summarize without uploading.

## How reprocessing works

Rows are keyed on `(term, course_code, sec_code)` and written with an upsert, so
loading the same file twice converges on the same table. Nothing is deleted
unless you ask for it by name.

That is the opposite of the scraper, deliberately. Testudo data is a snapshot
that goes stale, so the scraper clears each table before writing. Grade data
accumulates: each file is a permanent record of one term, and terms only ever
get added.

Every completed load is logged to `grade_ingests` with the file's SHA-256, so
re-running over a directory skips files already seen. A corrected file from the
Registrar has a different hash and is loaded even under the same name.

## Reading the files

There is no stable format. Between Fall 2010 and Spring 2026 the Registrar
exported these five different ways, and the filenames are inconsistent too
(`Spring -2012`, `distribuiton Fall 2011`, `grades Spring 2017`).

| Variant | Terms | What is different |
| :-- | :-- | :-- |
| Legacy report dump | F10 – S20 | Title, banner, and rule lines before the header; some begin with a form feed |
| `Lead\|Sect` header | F21 – S23 | Columns renamed |
| …plus a `GPA` column | S21 only | An extra column shifts everything right |
| Unquoted names | F22 only | `Walsh, Shane Bolles` written without quotes, splitting across two fields |
| `GR_` prefixed header | F23 onward | Two spellings: `GR_A-` and `GR_AM` |

Rather than switching on the term, `parse.py` finds the header row and maps
whatever it finds there through `HEADER_ALIASES`. When the next export arrives
with a sixth spelling, add the new column names to that dict; no new code path
is needed. If the header cannot be mapped at all the file is rejected loudly
rather than being loaded wrong.

## Three things about this data worth knowing

**Fall 2022 changes alignment mid-file.** Instructor names were written without
quoting, so a row with a comma'd name occupies one more field than a row with a
blank or single-token name. Both end up at twenty fields because the export also
carries a trailing empty column, so row length cannot tell them apart. The
parser resolves it per row by testing whether the cell after the name parses as
an integer.

**Before Fall 2017, `total` does not equal the sum of the grade columns.** In
every term from Spring 2011 to Spring 2017, about a quarter of rows report a
total exceeding the bucket sum by one to five students — roughly 2,700 students
per term, always in that direction. Those are enrolled students the older report
did not categorize, including into "Other". From Fall 2017 it reconciles
exactly. **Percentages computed against `total` are therefore not comparable
across that boundary**; use `graded` as the denominator. The loader records the
gap per file in `grade_ingests.unaccounted_students` rather than silently
rebalancing it.

**About a quarter of rows have no instructor.** The export names the instructor
once against the lead section and leaves the rows beneath it blank, which is
what the "Lead" banner over the section column means. The loader carries the
name forward within a course and records how far it reached in
`instructor_source`:

| value | share | meaning |
| :-- | --: | :-- |
| `reported` | 74% | Named directly by the Registrar. |
| `lead` | 21% | Carried within a lecture group (`0101` → `0102`). These are that lecture's discussion and lab sections, and their students really are that instructor's. |
| `course` | 2% | Carried across lecture groups (`0101` → `0201`) or into a differently-coded offering (`0101` → `FC01`). **Unreliable.** |
| null | 3% | No section of the course was ever named. |

The `course` tier is separated out because it is demonstrably wrong sometimes.
MATH113 in Fall 2019 names Darcy Conant on sections `FC05` and `FC06` while
leaving `FC01`–`FC04` blank, so carrying the lecturer into those rows would
attribute another instructor's Freshman Connection students to them. The default
instructor aggregates exclude it; `/v0/grades/summary?includeCarried=true` opts
back in.

The GPA column that appears in the Spring 2021 file only is read and discarded.
It is not reproducible from the counts in its own file — fitting the weights by
least squares suggests a denominator of roughly `total` including withdrawals,
but residuals stay around ±0.05 with outliers past 1.0. GPA is computed instead,
on the UMD 4.0 scale over letter grades only, by `umd_gpa()` in `schema.sql`.

## What ends up in the database

`grades`, one row per `(term, course_code, sec_code)`, with `graded` and `gpa`
as generated columns so PostgREST can filter and sort on them without any
application code. Five views aggregate it — `grade_terms`, `course_grades`,
`course_term_grades`, `course_instructor_grades`, and
`course_instructor_grades_all` — which is what keeps the Go API a thin proxy.

The current release is 32 files, Fall 2010 through Spring 2026, fall and spring
only, parsing to 210,122 section-level rows.

## Files

| file | purpose |
| :-- | :-- |
| `main.py` | CLI: `ingest`, `verify`, `terms` |
| `parse.py` | Format detection and row normalization; no I/O beyond reading its input |
| `terms.py` | Term codes from messy filenames |
| `db.py` | Supabase upserts and the ingest log |
| `schema.sql` | Table, indexes, GPA function, and views |

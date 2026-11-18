from tabulate import tabulate
import os
from supabase import create_client, Client
import textwrap

def get_supabase_client() -> Client:
    url = os.getenv("DATABASE_URL")
    if not url:
        raise EnvironmentError("DATABASE_URL not set in environment")
    key = os.getenv("DATABASE_KEY")
    if not key:
        raise EnvironmentError("DATABASE_KEY not set in environment")
    return create_client(url, key)

def print_as_table(data, wrap_width=36):
    if not data:
        print("No data found.")
        return

    # Wrap long values in each row
    wrapped_data = []
    for item in data:
        wrapped_item = {
            key: textwrap.fill(str(value), width=wrap_width)
            for key, value in item.items()
        }
        wrapped_data.append(wrapped_item)

    headers = wrapped_data[0].keys()
    rows = [item.values() for item in wrapped_data]
    print(tabulate(rows, headers=headers, tablefmt="grid"))

def replace_catalog(depts, courses, sections, print_output):
    '''
    Replace the scraped catalog in one transaction through the
    `replace_catalog()` database function.

    Pass None for any table this run does not replace; it is left as it is.
    Doesn't upload if `print_output` is enabled.

    The tables used to be replaced with a delete and then an insert per table,
    as separate requests. A reader between the two saw an empty table, and the
    API cached it: on 2026-11-17 that emptied the department list and broke
    course search on the site for an hour. One call is one transaction, so
    readers see the old catalog until it commits. See
    supabase/migrations/20261117120000_replace_catalog.sql.

    Instructors, aliases, grades and reviews are not snapshot data and must
    never be replaced this way; they have their own writers
    (instructor_registry.py, grades/db.py).
    '''
    dept_rows = None if depts is None else [{"dept_code": d[0], "name": d[1]} for d in depts]

    if print_output:
        for rows in (dept_rows, courses, sections):
            if rows is not None:
                print_as_table(rows)
        return

    # Refused by the database too; checked here so the error names the cause
    # before a multi-megabyte request is sent.
    for name, rows in (("departments", dept_rows), ("courses", courses), ("sections", sections)):
        if rows is not None and len(rows) == 0:
            raise ValueError(f"refusing to replace {name} with an empty scrape")

    client = get_supabase_client()
    client.rpc("replace_catalog", {
        "p_departments": dept_rows,
        "p_courses": courses,
        "p_sections": sections,
    }).execute()

def download_course_codes(dept_opt: str | None):
    # Continues to send requests until the API returns less than 500.
    full_courses = []
    offset = 0
    response_full = True
    dept = dept_opt if dept_opt else ""
    client = get_supabase_client()
    while response_full:
        print(f"Getting courses from DB with offset: {offset}")
        courses = client.table("courses").select("course_code").ilike("course_code", f"{dept}*").range(offset, offset + 499).execute().data
        full_courses += courses
        offset += len(courses)
        if len(courses) < 500:
            response_full = False
    return full_courses

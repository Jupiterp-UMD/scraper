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

def upload_depts(depts, print_output):
    '''
    Doesn't upload if `print_output` is enabled
    '''
    if print_output:
        print_as_table([{"dept_code": d[0], "dept_name": d[1]} for d in depts])
    else:
        client = get_supabase_client()

        # Delete all current data to avoid having stale data
        client.table("departments").delete().neq("dept_code", "").execute()

        # Upload data
        dept_data = [{"dept_code": d[0], "name": d[1]} for d in depts]
        client.table("departments").insert(dept_data).execute()

# Tables that must never be cleared and reloaded.
#
# `upload_data` exists because Testudo data is a snapshot: courses and sections
# go stale, so each run replaces them wholesale. Instructor identity is the
# opposite. `instructor_aliases` rows are append-only and deleting one orphans
# every grade row matched through it, and `reviews` will hold user-submitted
# content with `on delete cascade` back to `instructors` - so a nightly
# delete-all here would silently destroy every review in the database.
#
# This is a guard rather than a comment because the `instructors` branch of
# this function was removed rather than never existing, and the obvious way to
# add a new table to the nightly scrape is to copy the line above.
NEVER_TRUNCATE = frozenset({
    'instructors',
    'instructor_aliases',
    'instructor_match_queue',
    'section_instructors',
    'grades',
    'grade_ingests',
    'reviews',
})

def upload_data(data, print_output, table):
    '''
    Replace the contents of a snapshot table.

    Doesn't upload if `print_output` is enabled.
    '''
    if table in NEVER_TRUNCATE:
        raise ValueError(
            f"'{table}' is append/upsert-only and must not be truncated; "
            f"use the dedicated writer for it (see instructor_registry.py "
            f"for instructors, grades/db.py for grades)"
        )

    if print_output:
        print_as_table(data)
    else:
        client = get_supabase_client()

        # Delete all current data to avoid having stale data. `gte('', '')` is
        # true for every non-null text value, which is the PostgREST way of
        # saying "all rows"; the previous `neq(col, 0)` compared a text column
        # to an integer and worked only by accident of coercion.
        client.table(table).delete().gte('course_code', '').execute()

        # Upload data
        client.table(table).insert(data).execute()

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

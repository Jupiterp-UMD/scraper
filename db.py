from tabulate import tabulate
import os
from supabase import create_client, Client
import textwrap

def get_supabase_client() -> Client:
    url = os.getenv("DATABASE_URL")
    key = os.getenv("DATABASE_KEY")
    if not url or not key:
        raise EnvironmentError("DATABASE_URL or DATABASE_KEY not set in environment")
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

def upload_data(data, print_output, table):
    '''
    Doesn't upload if `print_output` is enabled
    '''
    if print_output:
        print_as_table(data)
    else:
        client = get_supabase_client()

        # Delete all current data to avoid having stale data
        comparison_col = 'course_code' if table != 'instructors' else 'slug'
        client.table(table).delete().neq(comparison_col, 0).execute()

        # Upload data
        client.table(table).insert(data).execute()

def download_course_codes(dept_opt: str | None):
    dept = dept_opt if dept_opt else ""
    client = get_supabase_client()
    courses = client.table("courses").select("course_code").ilike("course_code", f"{dept}*").execute().data
    return courses

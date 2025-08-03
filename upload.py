import json
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

def print_as_json(data):
    print(json.dumps(data, indent=2))

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

def upload_to_supabase(data):
    client = get_supabase_client()
    table = client.table("courses")
    for entry in data:
        response = table.upsert(entry).execute()
        if response.get("status_code") != 201:
            print(f"Failed to insert: {entry}", file=sys.stderr)

def upload_courses(data, print_output):
    '''
    Doesn't upload if `print_output` is enabled.
    '''
    if print_output:
        print_as_table(data)
    else:
        upload_to_supabase(data)
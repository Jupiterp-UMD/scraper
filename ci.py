from db import get_supabase_client
import os
import requests

def send_alert(table_name: str):
    """
    Sends an alert by opening a GitHub issue and tagging Andrew (@atcupps).
    This should be modified with a rotation if more people join.
    """
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        print("GITHUB_TOKEN is not set.")
        exit(1)
    repo = "jupiterp-umd/scraper"
    title = f"Table {table_name} is not populated with enough data"
    body = f"@atcupps Please investigate why the {table_name} table is not populated with enough data."
    assignees = ["atcupps"]

    url = f"https://api.github.com/repos/{repo}/issues"

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json"
    }

    data = {
        "title": title,
        "body": body,
        "assignees": assignees
    }

    response = requests.post(url, headers=headers, json=data)
    if response.status_code != 201:
        print("Failed to create GitHub issue.")
        print(response.json())
        exit(1)

def verify_supabase_populated():
    """
    Checks that all tables have a lot of rows. The amount is arbitrarily chosen
    based on what is considered to be a reasonable amount and may require
    manual adjustment. This should probably be replaced with better CI that
    randomly checks classes on Testudo to make sure they are in the DB.
    """
    client = get_supabase_client()
    rows = client.table("courses").select("course_code", count="exact").execute()
    length = rows.count
    print(f"Found {length} rows in courses table.")
    if not rows or rows.count < 2000:
        print(f"Table courses is not populated with enough data ({length} < 2000). Something must be wrong.")
        send_alert("table")
        exit(1)
    rows = client.table("sections").select("course_code, sec_code", count="exact").execute()
    length = rows.count
    print(f"Found {length} rows in sections table.")
    if not rows or rows.count < 7000:
        print(f"Table sections is not populated with enough data ({length} < 7000). Something must be wrong.")
        send_alert("sections")
        exit(1)
    rows = client.table("instructors").select("*", count="exact").execute()
    length = rows.count
    print(f"Found {length} rows in instructors table.")
    if not rows or rows.count < 13000:
        print(f"Table instructors is not populated with enough data ({length} < 13000). Something must be wrong.")
        send_alert("instructors")
        exit(1)
    rows = client.table("active_instructors").select("*", count="exact").execute()
    length = rows.count
    print(f"Found {length} rows in active_instructors table.")
    if not rows or rows.count < 2500:
        print(f"Table active_instructors is not populated with enough data ({length} < 2500). Something must be wrong.")
        send_alert("active_instructors")
        exit(1)

    print("Successfully verified all tables.")

if __name__ == "__main__":
    verify_supabase_populated()
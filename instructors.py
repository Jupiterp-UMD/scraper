import requests
from time import sleep

# Send a request to PlanetTerp API; return JSON-parsed list of dicts.
# Takes limit and offset as parameters to send to API.
def send_request(term: str, limit: int, offset: int):
    uri = f"https://planetterp.com/api/v1/professors?type=professor&limit={limit}&offset={offset}"

    headers = {
        "User-Agent": "Mozilla/5.0",
        "Content-Type": "application/x-www-form-urlencoded"
    }

    response = requests.get(uri, headers)
    if response.status_code != 200:
        raise Exception(f"Failed to fetch data: {response.status_code}: {response.reason}")
    
    return response.json()

# Gets data on all instructors from PlanetTerp API. Sends requests to get 100
# instructors at a time, with requests separated by 500 ms as requested by the
# PlanetTerp team.
def get_instructors(term: str):
    # Continues to send requests until the API returns a number of instructors
    # less than 100.
    full_instructors = []
    offset = 0
    response_full = True
    while response_full:
        sleep(0.5)
        print(f"Getting professors from PlanetTerp API with offset: {offset}")
        instructors = send_request(term, 100, offset)
        full_instructors += instructors
        offset += len(instructors)
        if len(instructors) < 100:
            response_full = False
    
    return [
        {
            "slug": i["slug"],
            "name": i["name"],
            "average_rating": i["average_rating"]
        } for i in full_instructors
    ]
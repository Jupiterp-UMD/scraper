from bs4 import BeautifulSoup
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from progress import SectionScrapingProgress
import requests

# Logging progress
sections_progress = SectionScrapingProgress()

# Attempts to send the request a total of 3 times by default.
# Testudo can be flaky sometimes.
def send_request(uri: str, attempts_remaining=2) -> BeautifulSoup:
    headers = {
        "User-Agent": "Mozilla/5.0",
        "Content-Type": "application/x-www-form-urlencoded"
    }

    response = requests.post(uri, headers=headers)
    if response.status_code != 200:
        if attempts_remaining > 0:
            return send_request(uri, attempts_remaining - 1)
        else:
            raise Exception(f"Failed to fetch data: {response.status_code}")
    
    return BeautifulSoup(response.text, features='html.parser')

def split_into_chunks(items, num_chunks):
    k, m = divmod(len(items), num_chunks)
    return [items[i*k + min(i, m):(i+1)*k + min(i+1, m)] for i in range(num_chunks)]

def parse_async_class(div: BeautifulSoup):
    online_classroom = div.find('span', class_='class-room')
    if online_classroom != None:
        return 'OnlineAsync'
    return 'Unspecified'

def get_location(div: BeautifulSoup):
    location = div.find('span', class_='class-building')
    try_building = location.find('span', class_='building-code')
    try_classroom = location.find('span', class_='class-room')

    if try_building == None:
        return 'OnlineSync'
    
    building = try_building.get_text()
    classroom = try_classroom.get_text() if try_classroom != None else '????'

    return f'{building}-{classroom}'

def parse_meeting(div: BeautifulSoup):
    try_days = div.find('span', class_='section-days')
    if try_days == None:
        return parse_async_class(div)
    
    days = try_days.get_text()
    if days == 'TBA':
        return 'TBA'

    start = div.find('span', class_='class-start-time').get_text()
    end = div.find('span', class_='class-end-time').get_text()

    location = get_location(div)

    return f'{days}-{start}-{end}-{location}'

def parse_section(div: BeautifulSoup, course: str):
    sec_code = div.find('input', {'name': 'sectionId'})['value']
    instructors = list(
        map(lambda x: x.get_text(),
            div.find_all('span', class_='section-instructor')))
    meetings_divs = div.select('.class-days-container .row')
    meetings = list(map(parse_meeting, meetings_divs))
    open_seats = int(div.find('span', class_='open-seats-count').get_text())
    total_seats = int(div.find('span', class_='total-seats-count').get_text())
    try_waitlist_holdfile = div.find_all('span', class_='waitlist-count')
    waitlist = int(try_waitlist_holdfile[0].get_text())
    holdfile = None if len(try_waitlist_holdfile) == 1 else try_waitlist_holdfile[1].get_text()
    
    return {
        "course_code": course,
        "sec_code": sec_code,
        "instructors": instructors,
        "meetings": meetings,
        "open_seats": open_seats,
        "total_seats": total_seats,
        "waitlist": waitlist,
        "holdfile": holdfile
    }

def sections_for_course(course: str, page: BeautifulSoup, chunk_start: str, chunk_end: str):
    course_div = page.find('div', id=course)
    
    # some courses have no sections
    if course_div == None:
        return []

    sections = course_div.find_all('div', class_='section')
    section_with_sections_div = partial(parse_section, course=course)
    result = list(
        map(section_with_sections_div, filter(lambda x: x != None, sections))
    )
    sections_progress.increment_chunk_courses_parsed(chunk_start, chunk_end)
    return result

def get_sections_for_chunk(chunk: list[str], term: str):
    if len(chunk) == 0:
        return []

    sections_progress.mark_chunk_sending_req(chunk[0], chunk[-1])
    url = f'https://app.testudo.umd.edu/soc/{term}/sections?courseIds=' + ','.join(chunk)
    chunk_page = send_request(url)
    sections_progress.mark_chunk_parsing(chunk[0], chunk[-1], len(chunk))

    sections_for_course_with_page = partial(sections_for_course, page=chunk_page, chunk_start=chunk[0], chunk_end=chunk[-1])
    sections = list(map(sections_for_course_with_page, chunk))
    sections_progress.mark_chunk_complete(chunk[0], chunk[-1])
    return [section for sublist in sections for section in sublist]

def scrape_sections(term: str, courses):
    course_codes = list(map(lambda x: x["course_code"], courses))
    chunks = split_into_chunks(items=course_codes, num_chunks=50)
    get_sections_for_chunk_with_term = partial(get_sections_for_chunk, term=term)
    workers = 5
    sections_progress.courses_sections_to_parse = len(courses)
    sections_progress.start_logging(num_workers=workers)
    with ThreadPoolExecutor(max_workers=workers) as executor:
        sections_lists = list(executor.map(get_sections_for_chunk_with_term, chunks))
    sections_progress.stop_logging()
    sections = [section for sublist in sections_lists for section in sublist]
    return sections
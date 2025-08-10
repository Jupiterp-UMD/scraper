from bs4 import BeautifulSoup
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from progress import CourseScrapingProgress
import requests

# Logging progress
course_progress = CourseScrapingProgress()

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

def get_depts():
    soup = send_request("https://app.testudo.umd.edu/soc")
    depts = list(
        map(lambda x: x.get_text(), 
            soup.select("#course-prefixes-page .two")))
    return depts

def course_info(course: str, course_doc: BeautifulSoup):
    # Title of course
    title = course_doc.select_one(f"#{course} .course-title").get_text()
    
    # Min credits; also used as default for set number of credits
    min_credits = int(course_doc.select_one(f"#{course} .course-min-credits").get_text())
    
    # Max credits; if not a range, there is no max
    max_credits_raw = course_doc.select_one(f"#{course} .course-max-credits")
    if max_credits_raw is None:
        max_credits = None
    else:
        max_credits = int(max_credits_raw.get_text())
    
    # GenEds
    gen_eds = list(
        map(lambda x: x.get_text(),
            course_doc.select(f"#{course} .course-subcategory a")))
    if len(gen_eds) == 0:
        gen_eds = None

    # Conditions (e.g. prerequisites)
    conditions = list(
        map(lambda x: x.get_text(),
            course_doc.select(f"#{course} .approved-course-texts-container :nth-child(1) .approved-course-text > div > div > div")))
    if len(conditions) == 0:
        conditions = None
    
    # Course description
    description_raw = course_doc.select_one(f"#{course} .approved-course-texts-container :nth-child(2) .approved-course-text")
    if description_raw is None:
        description_raw = course_doc.select_one(f"#{course} .approved-course-text")
    if description_raw is None:
        description_raw = course_doc.select_one(f"#{course} .course-text")
    description = None if description_raw is None else description_raw.get_text()

    course_progress.increment_courses_parsed()

    return {
        "course_code": course,
        "name": title,
        "min_credits": min_credits,
        "max_credits": max_credits,
        "gen_eds": gen_eds,
        "conditions": conditions,
        "description": description,
    }

def get_courses_for_dept(dept: str, term: str):
    course_progress.mark_dept_sending_req(dept)
    course_doc = send_request(f"https://app.testudo.umd.edu/soc/{term}/{dept}")
    course_progress.mark_dept_parsing(dept)

    # Get all course IDs
    course_ids = list(
        map(lambda x: x.get_text(),
            course_doc.find_all(class_="course-id")))
    course_progress.increment_courses_resolved(len(course_ids))

    # Get all course info and return
    course_info_fn_with_docs = partial(course_info, course_doc=course_doc)
    result = list(map(course_info_fn_with_docs, course_ids))

    course_progress.mark_dept_complete(dept)
    return result

def scrape_courses(term: str, dept: str):
    depts = [dept] if dept else get_depts()
    course_progress.total_depts = len(depts)
    get_courses_for_dept_with_term = partial(get_courses_for_dept, term=term)
    workers = 4
    course_progress.start_logging(num_workers=workers)
    with ThreadPoolExecutor(max_workers=workers) as executor:
        courses_lists = list(executor.map(get_courses_for_dept_with_term, depts))
    course_progress.stop_logging()
    courses = [course for sublist in courses_lists for course in sublist]
    return courses
import argparse
from courses import scrape_courses
from sections import scrape_sections
from instructors import get_instructors
from db import upload_data, download_course_codes

def parse_args():
    parser = argparse.ArgumentParser(description="Scrape Testudo Schedule of Classes")
    parser.add_argument("--term", help="Term to scrape (e.g., '202508' for Fall 2025)")
    parser.add_argument("--print-output", action="store_true", help="Output results to stdout instead of uploading to DB")
    parser.add_argument("--department", help="Specific department (e.g., CMSC)")
    parser.add_argument("--courses", action="store_true", help="Scrape, parse, and upload all courses")
    parser.add_argument("--sections", action="store_true", help="Scrape, parse, and upload all sections; if `--courses` is not enabled, uses list of courses already present in courses database")
    parser.add_argument("--instructors", action="store_true", help="Scrape, parse, and upload all instructors from PlanetTerp")
    return parser.parse_args()

def main():
    args = parse_args()

    # Get courses; if section scraping is enabled but courses isn't, get
    # list of courses from DB.
    if args.courses:
        course_data = scrape_courses(args.term, args.department)
    elif args.sections:
        course_data = download_course_codes(args.department)
    else:
        course_data = []
    course_codes = [course["course_code"] for course in course_data]
    
    # Scrape sections from Testudo
    if args.sections:
        sections_data = scrape_sections(args.term, course_codes)

    # Upload courses and sections to DB
    if args.courses:
        upload_data(course_data, args.print_output, table='courses')
    if args.sections:
        upload_data(sections_data, args.print_output, table='sections')

    # Get instructors from PlanetTerp API and upload to DB
    if args.instructors:
        instructors_data = get_instructors(args.term)
        upload_data(instructors_data, args.print_output, table='instructors')

if __name__ == "__main__":
    main()

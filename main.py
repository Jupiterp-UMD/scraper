import argparse
from courses import scrape_courses
from sections import scrape_sections
from db import upload_data, download_course_codes

def parse_args():
    parser = argparse.ArgumentParser(description="Scrape Testudo Schedule of Classes")
    parser.add_argument("--term", help="Term to scrape (e.g., '202508' for Fall 2025)")
    parser.add_argument("--print-output", action="store_true", help="Output results to stdout instead of uploading to DB")
    parser.add_argument("--department", help="Specific department (e.g., CMSC)")
    parser.add_argument("--only-sections", action="store_true", help="Only scrapes and uploads section data, instead of courses. Uses the list of courses already present in the courses database table.")
    return parser.parse_args()

def main():
    args = parse_args()

    if not args.only_sections:
        course_data = scrape_courses(args.term, args.department)
    else:
        course_data = download_course_codes(args.department)
    course_codes = [course["course_code"] for course in course_data]
    sections_data = scrape_sections(args.term, course_codes)

    if not args.only_sections:
        upload_data(course_data, args.print_output, table='Courses')
    upload_data(sections_data, args.print_output, table='Sections')

if __name__ == "__main__":
    main()

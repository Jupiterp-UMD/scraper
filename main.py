import argparse
from courses import scrape_courses, get_depts
from sections import scrape_sections
from instructor_registry import reconcile_instructors
from db import upload_data, download_course_codes, upload_depts
from dotenv import load_dotenv

def parse_args():
    parser = argparse.ArgumentParser(description="Scrape Testudo Schedule of Classes")
    parser.add_argument("--term", help="Term to scrape (e.g., '202508' for Fall 2025)")
    parser.add_argument("--print-output", action="store_true", help="Output results to stdout instead of uploading to DB")
    parser.add_argument("--department", help="Specific department (e.g., CMSC)")
    parser.add_argument("--courses", action="store_true", help="Scrape, parse, and upload all courses")
    parser.add_argument("--sections", action="store_true", help="Scrape, parse, and upload all sections; if `--courses` is not enabled, uses list of courses already present in courses database")
    return parser.parse_args()

def main():
    load_dotenv()

    args = parse_args()

    # Get depts, unless department is specified.
    if args.department:
        depts = ([args.department], "")
    else:
        depts = get_depts(args.term)
    deptCodes = [d[0] for d in depts]

    # Get courses; if section scraping is enabled but courses isn't, get
    # list of courses from DB.
    if args.courses:
        course_data = scrape_courses(args.term, deptCodes)
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
        if not args.department:
            upload_depts(depts, args.print_output)
        upload_data(course_data, args.print_output, table='courses')
    if args.sections:
        upload_data(sections_data, args.print_output, table='sections')

        # Testudo is now the source of instructor records. Every name in the
        # scrape is resolved to an instructor id, new professors are created,
        # and anything ambiguous goes to `instructor_match_queue` for a human
        # rather than being guessed at. This replaces the nightly PlanetTerp
        # instructor scrape, which no longer exists.
        term = int(args.term) if args.term else None
        report = reconcile_instructors(sections_data, term, args.print_output)
        print(f"Instructors: {report}")

if __name__ == "__main__":
    main()

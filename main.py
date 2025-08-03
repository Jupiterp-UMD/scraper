import argparse
import sys
from courses import scrape_courses
from sections import scrape_sections
from upload import upload_courses

def parse_args():
    parser = argparse.ArgumentParser(description="Scrape Testudo Schedule of Classes")
    parser.add_argument("--term", help="Term to scrape (e.g., '202508' for Fall 2025)")
    parser.add_argument("--print-output", action="store_true", help="Output results to stdout instead of uploading to DB")
    parser.add_argument("--department", help="Specific department (e.g., CMSC)")
    return parser.parse_args()

def main():
    args = parse_args()

    course_data = scrape_courses(args.term, args.department)
    sections_data = scrape_sections(args.term, course_data)

    upload_courses(course_data, args.print_output)
    upload_courses(sections_data, args.print_output)

if __name__ == "__main__":
    main()

import argparse
import sys
from scraper import scrape_schedule
from output import output_results

def parse_args():
    parser = argparse.ArgumentParser(description="Scrape Testudo Schedule of Classes")
    parser.add_argument("--term", help="Term to scrape (e.g., '202508' for Fall 2025)")
    parser.add_argument("--test-json", action="store_true", help="Output results as JSON to stdout")
    parser.add_argument("--test-table", action="store_true", help="Output results as a table")
    parser.add_argument("--department", help="Specific department (e.g., CMSC)")
    parser.add_argument("--course", help="Specific course (e.g., CMSC132)")
    return parser.parse_args()

def main():
    args = parse_args()
    if args.department and args.course:
        print("Error: Cannot specify both department and course.", file=sys.stderr)
        sys.exit(1)

    data = scrape_schedule(args.term, args.department, args.course)
    output_results(data, args.test_json, args.test_table)

if __name__ == "__main__":
    main()

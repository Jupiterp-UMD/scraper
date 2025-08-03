import colorama
from colorama import Fore, Style
import sys
import threading
import time

class CourseScrapingProgress:
    '''
    Keeps track and logs the number of courses resolved vs. parsed.
    '''
    def __init__(self, interval=0.5):
        '''
        `interval`: time in second between logs
        '''
        colorama.init()
        self.courses_resolved = 0
        self.courses_parsed = 0
        self.total_depts = 0
        self.depts_complete = 0
        self.depts_in_progress = dict()
        self.lock = threading.Lock()
        self.logging_enabled = threading.Event()
        self.logging_thread = None
        self.num_workers = 0
        self.interval = interval
        self.start_time = None

    def increment_courses_resolved(self, amount=1):
        with self.lock:
            self.courses_resolved += amount

    def increment_courses_parsed(self):
        with self.lock:
            self.courses_parsed += 1

    def mark_dept_sending_req(self, dept: str):
        with self.lock:
            self.depts_in_progress[dept] = 0
    
    def mark_dept_parsing(self, dept: str):
        with self.lock:
            self.depts_in_progress[dept] = 1

    def mark_dept_complete(self, dept: str):
        with self.lock:
            self.depts_complete += 1
            self.depts_in_progress.pop(dept)

    def start_logging(self, num_workers: int):
        if not self.logging_enabled.is_set():
            self.num_workers = num_workers
            self.start_time = time.perf_counter()
            self.logging_enabled.set()
            self.logging_thread = threading.Thread(target=self._log_status, daemon=True)
            self.logging_thread.start()

    def stop_logging(self):
        self.logging_enabled.clear()
        if self.logging_thread:
            self.logging_thread.join()

    def _log_status(self):
        while self.logging_enabled.is_set():
            with self.lock:
                cur_time = time.perf_counter()
                elapsed_time = cur_time - self.start_time

                print("\033[2K", end='')  # Clear line
                print(f"{Fore.WHITE}{Style.BRIGHT}Scraping and parsing all courses...{Style.RESET_ALL}")
                print("\033[2K", end='')
                print(f"{Fore.WHITE}{Style.DIM}(Elapsed time: {elapsed_time:.0f} seconds){Style.RESET_ALL}")
                print("\033[2K", end='')
                print(f"\tCourses resolved: {Fore.GREEN}{Style.BRIGHT}{self.courses_resolved}{Style.RESET_ALL}")
                print("\033[2K", end='')
                print(f"\tCourses parsed: {Fore.GREEN}{Style.BRIGHT}{self.courses_parsed}{Style.RESET_ALL}")
                print("\033[2K", end='')
                print(f"\tCompleted parsing for {Fore.GREEN}{Style.BRIGHT}{self.depts_complete}{Style.RESET_ALL} of {Fore.GREEN}{Style.BRIGHT}{self.total_depts}{Style.RESET_ALL} departments")
                
                for dept in self.depts_in_progress:
                    if self.depts_in_progress[dept] == 0:
                        progress = f"{Fore.WHITE}{Style.DIM}Request sent, awaiting response"
                    else:
                        progress = f"{Fore.WHITE}{Style.NORMAL}Parsing response"
                    print("\033[2K", end='')
                    print(f"\t\t{Fore.CYAN}{Style.BRIGHT}{dept}{Style.RESET_ALL}: {progress}{Style.RESET_ALL}")
                
                for _ in range(self.num_workers - len(self.depts_in_progress)):
                    print("\033[2K", end='')
                    print(f"\t\t{Fore.YELLOW}{Style.DIM}1 worker idle{Style.RESET_ALL}")
                
                num_lines = 5 + self.num_workers
                sys.stdout.write(f"\033[{num_lines}A")
                sys.stdout.flush()
            time.sleep(self.interval)
            
        # Move to next line after logging ends
        print("\033[2K", end='')
        print("Scraping and parsing all courses complete.")
'''
Section parsing against the three shapes Testudo gives the seats block.

The nightly scrape died on the third of them - a section with no waitlist at
all - because the two counts were read out of `waitlist-count` by position and
that markup contains no `waitlist-count` spans. One such section in a chunk
raised `IndexError` out of the thread pool and took the entire run with it,
which is why these are pinned as fixtures rather than trusted to stay stable.
'''

import os
import sys

from bs4 import BeautifulSoup
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sections import parse_section, parse_waitlist_and_holdfile


def section(seats_info: str, sec_code: str = '0101') -> BeautifulSoup:
    html = f'''
    <div class="section">
      <input type="hidden" name="sectionId" value="{sec_code}"/>
      <span class="section-instructor">Ada Lovelace</span>
      <span class="seats-info">{seats_info}</span>
    </div>
    '''
    return BeautifulSoup(html, 'html.parser').find('div', class_='section')


# A section with a waitlist and no holdfile: one `waitlist-count` span.
WAITLIST_ONLY = '''
  <span class="total-seats">(<span class="seats-info-label">Total:</span>
    <span class="total-seats-count">35</span>,</span>
  <span class="open-seats has-open-seats"><span class="seats-info-label">Open:</span>
    <span class="open-seats-count">14</span>,</span>
  <span class="waitlist">
    <a href="https://registrar.umd.edu/registration/register-classes/waitlist-hold-file">
      <span class="seats-info-label">Waitlist:</span>
      <span class="waitlist-count">3</span>
    </a>)
  </span>
'''

# A full section that also runs a holdfile: two spans of the *same* class,
# distinguished only by the label in front of each.
WAITLIST_AND_HOLDFILE = '''
  <span class="total-seats">(<span class="seats-info-label">Total:</span>
    <span class="total-seats-count">90</span>,</span>
  <span class="open-seats"><span class="seats-info-label">Open:</span>
    <span class="open-seats-count">0</span>,</span>
  <span class="waitlist has-waitlist">
    <a href="https://registrar.umd.edu/registration/register-classes/waitlist-hold-file">
      <span class="seats-info-label">Waitlist:</span>
      <span class="waitlist-count">7</span>
      <span class="seats-info-label">Holdfile:</span>
      <span class="waitlist-count">2</span>
    </a>)
  </span>
'''

# The shape that broke the scrape: the `waitlist` wrapper is emitted with the
# help link inside it but carries no counts whatsoever.
NO_WAITLIST = '''
  <span class="total-seats">(<span class="seats-info-label">Total:</span>
    <span class="total-seats-count">12</span>,</span>
  <span class="open-seats has-open-seats"><span class="seats-info-label">Open:</span>
    <span class="open-seats-count">10</span>,</span>
  <span class="waitlist">
    <a href="https://registrar.umd.edu/registration/register-classes/waitlist-hold-file"></a>)
  </span>
'''


@pytest.mark.parametrize('seats_info,expected', [
    (WAITLIST_ONLY, (3, None)),
    (WAITLIST_AND_HOLDFILE, (7, 2)),
    (NO_WAITLIST, (0, None)),
])
def test_waitlist_and_holdfile(seats_info, expected):
    assert parse_waitlist_and_holdfile(section(seats_info)) == expected


def test_section_without_waitlist_still_parses():
    '''
    The regression itself: this raised `IndexError` and aborted the term.
    '''
    parsed = parse_section(section(NO_WAITLIST), 'BMGT848A')

    assert parsed['course_code'] == 'BMGT848A'
    assert parsed['sec_code'] == '0101'
    assert parsed['open_seats'] == 10
    assert parsed['total_seats'] == 12
    assert parsed['waitlist'] == 0
    assert parsed['holdfile'] is None


def test_holdfile_is_a_number():
    '''
    `holdfile` is typed `number | null` by the site, so it must not come back
    as the raw span text.
    '''
    parsed = parse_section(section(WAITLIST_AND_HOLDFILE), 'CMSC131')

    assert parsed['waitlist'] == 7
    assert parsed['holdfile'] == 2


def test_labels_are_not_trusted_to_order_the_counts():
    '''
    Counts are keyed off their labels, so a holdfile listed first still lands
    in the right field.
    '''
    reordered = WAITLIST_AND_HOLDFILE.replace(
        '<span class="seats-info-label">Waitlist:</span>\n      <span class="waitlist-count">7</span>\n      '
        '<span class="seats-info-label">Holdfile:</span>\n      <span class="waitlist-count">2</span>',
        '<span class="seats-info-label">Holdfile:</span>\n      <span class="waitlist-count">2</span>\n      '
        '<span class="seats-info-label">Waitlist:</span>\n      <span class="waitlist-count">7</span>'
    )
    assert reordered != WAITLIST_AND_HOLDFILE, 'fixture rewrite did not apply'
    assert parse_waitlist_and_holdfile(section(reordered)) == (7, 2)

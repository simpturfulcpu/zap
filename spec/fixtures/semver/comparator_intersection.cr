# Adapted from: https://github.com/npm/node-semver/blob/main/test/fixtures/comparator-intersection.js
# {comparator1, comparator2, expected intersection}
COMPARATOR_INTERSECTION_FIXTURES = {
  # One is a Version
  {"1.3.0", ">=1.3.0", "1.3.0"},
  {"1.3.0", ">1.3.0", ""},
  {">=1.3.0", "1.3.0", "1.3.0"},
  {">1.3.0", "1.3.0", ""},
  # Same direction increasing
  {">1.3.0", ">1.2.0", ">1.3.0"},
  {">1.2.0", ">1.3.0", ">1.3.0"},
  {">=1.2.0", ">1.3.0", ">1.3.0"},
  {">1.2.0", ">=1.3.0", ">=1.3.0"},
  # Same direction decreasing
  {"<1.3.0", "<1.2.0", "<1.2.0"},
  {"<1.2.0", "<1.3.0", "<1.2.0"},
  {"<=1.2.0", "<1.3.0", "<=1.2.0"},
  {"<1.2.0", "<=1.3.0", "<1.2.0"},
  # Different directions, same semver and inclusive operator
  {">=1.3.0", "<=1.3.0", "1.3.0"},
  {">=1.3.0", ">=1.3.0", ">=1.3.0"},
  {"<=1.3.0", "<=1.3.0", "<=1.3.0"},
  {">1.3.0", "<=1.3.0", ""},
  {">=1.3.0", "<1.3.0", ""},
  # Opposite matching directions
  {">1.0.0", "<2.0.0", ">1.0.0 <2.0.0"},
  {">=1.0.0", "<2.0.0", ">=1.0.0 <2.0.0"},
  {">=1.0.0", "<=2.0.0", ">=1.0.0 <=2.0.0"},
  {">1.0.0", "<=2.0.0", ">1.0.0 <=2.0.0"},
  {"<=2.0.0", ">1.0.0", ">1.0.0 <=2.0.0"},
  {"<=1.0.0", ">=2.0.0", ""},
  {"", "", ">=0.0.0"},
  {"", ">1.0.0", ">1.0.0"},
  {"<=2.0.0", "", "<=2.0.0"},
  {"<0.0.0", "<0.1.0", ""},
  {"<0.1.0", "<0.0.0", ""},
  {"<0.0.0-0", "<0.1.0", ""},
  {"<0.1.0", "<0.0.0-0", ""},
  {"<0.0.0-0", "<0.1.0", ""},
  {"<0.1.0", "<0.0.0-0", ""},
  # # Custom cases
  {"<=0.2.0 <0.2.0 >0.1.0 >=0.1.0", "<=0.2.0 <0.2.0 >0.1.0 >=0.1.0", ">0.1.0 <0.2.0"},
  {"1.x", ">1.0.0", ">1.0.0 <2.0.0"},
  # Prereleases
  {">1.2.0-alpha.0", ">1.2.0-alpha.2", ">1.2.0-alpha.2"},
  {">=1.2.0-alpha.0", ">1.2.0-alpha.2", ">1.2.0-alpha.2"},
  {">1.2.0-alpha.0", ">=1.2.0-alpha.2", ">=1.2.0-alpha.2"},
  {">=1.2.0-alpha.0", "<1.2.0-alpha.2", ">=1.2.0-alpha.0 <1.2.0-alpha.2"},
  {">1.2.0-alpha.0", "<=1.2.0-alpha.2", ">1.2.0-alpha.0 <=1.2.0-alpha.2"},
  {">1.2.0-alpha.0", ">1.2.0-beta", ">1.2.0-beta"},
  {">=1.2.0-alpha.0", "<1.2.0-beta", ">=1.2.0-alpha.0 <1.2.0-beta"},
  {"<1.2.0-alpha", "<1.2.0-beta", "<1.2.0-alpha"},
  {"<1.2.1-alpha", "<1.2.0-beta", ""},
  {"<1.2.1-alpha", "<1.2.1", ""},
  {"<1.2.1", "<1.2.1-beta", ""},
}

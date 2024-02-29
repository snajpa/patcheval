#!/usr/bin/env ruby

require 'terminal-table'
require 'colorize'
require 'csv'

csv_file = ARGV[0]

tests = ["bug-01", "stable-01", "vpsadminos-01", "security-01", "kpatch-build-02"]

if csv_file.nil?
  puts "Usage: #{$0} <csv_file> [apply <to_branch> | compare <csv_file> [compare <csv_file> ...]]"
  puts "  apply: try to cherry-pick commits to a new set of a new set of branches on top of <to_branch>"
  exit 1
end

apply = false
if ARGV[1] == "apply"
  to_branch = ARGV[2]
  branch_prefix = ARGV[3]
  if to_branch.nil?
    puts "Usage: #{$0} <csv_file> apply <to_branch>"
    exit 1
  end
  apply = true
end

compare_files = [csv_file]
compare = false
while ARGV[1] == "compare"
  compare_file = ARGV[2]
  if compare_file.nil?
    puts "Usage: #{$0} <csv_file> [apply <to_branch> | compare <csv_file> [compare <csv_file> ...]]"
    exit 1
  end
  compare = true
  compare_files << compare_file
  ARGV.shift(2)
end

def test_result(tests, name)
  return "N/A" if tests.nil?
  found = tests.find { |t| t[:name] == name }
  return "N/A" if found.nil?
  return found[:result]
end

def verdict(tests, msg_true, and_or, *args)
  return "N/A" if tests.nil?
  result = and_or == "and"
  args.each do |name|
    result = (and_or == "and") ? (result && test_result(tests, name) == "ok")
                               : (result || test_result(tests, name) == "ok")

  end
  result.to_s.colorize(result ? :green : :red)
end

def verdict_table(csv_file, tests)
  csv = CSV.read(csv_file)

  commits = {}
  
  csv.each do |row|
    commits[row[0]] ||= {
      message_short: row[1],
      tests: [],
      verdict: [],
    }
    commits[row[0]][:tests] << {
      name: row[2],
      result: row[3],
      prompt_name: row[4],
      predicted_n: row[5],
      elapsed: row[6],
    }
    #puts commits[row[0]]
  end
  
  table = Terminal::Table.new do |t|
    t.headings = ['id', 'msg'].concat(tests).append("LTS", "OS-LTS", "OS-LTS-SEC", "OS-LTS-KLP", "OS-LTS-KLP-SEC")
    t.style = { border_left: false, border_right: false }
  end

  commits.each do |commit, data|
    next if data.nil? || data[:tests].nil?
    #puts "%s: %s" % [commit, data[:message_short]]
    data[:tests].each do |test|
    end
    message_short = data[:message_short].length > 50 ? data[:message_short][0..50] + "..." : data[:message_short]
    row = [commit, message_short]
    tests.each do |test|
      found = data[:tests].find { |t| t[:name] == test }
      if found
        if found[:result] == "ok"
          color = :green
        elsif found[:result] == "fail"
          color = :red
        else
          color = :yellow
        end
        row << found[:result].colorize(color)
      else
        row << "N/A"
      end
    end
    row << verdict(data[:tests], "LTS",            "and", "bug-01", "stable-01")
    row << verdict(data[:tests], "OS-LTS",         "and", "bug-01", "vpsadminos-01")
    row << verdict(data[:tests], "OS-LTS-SEC",     "and", "bug-01", "vpsadminos-01", "security-01")
    row << verdict(data[:tests], "OS-LTS-KLP",     "and", "bug-01", "vpsadminos-01", "kpatch-build-02")
    row << verdict(data[:tests], "OS-LTS-KLP-SEC", "and", "bug-01", "vpsadminos-01", "security-01", "kpatch-build-02")
    data["LTS"], data["OS-LTS"], data["OS-LTS-SEC"], data["OS-LTS-KLP"], data["OS-LTS-KLP-SEC"] = row[-5..-1]
    table.add_row row
  end
  [table, commits]
end

filenums_commits = []
table, filenums_commits[0] = verdict_table(csv_file, tests)
puts csv_file
puts table
puts

exit 0 unless apply or compare

if compare
  commit_list = filenums_commits[0].keys

  filenums = (0..compare_files.length-1).to_a
  diff_table = Terminal::Table.new do |t|
    t.headings = ['commit', filenums, 'msg', 'diff', filenums].flatten
    t.style = { border_left: false, border_right: false }
  end
  filenums.each do |filenum|
    next if filenum == 0
    compare_table, filenums_commits[filenum] = verdict_table(compare_files[filenum], tests)
    puts compare_files[filenum]
    puts compare_table
    puts
    filenums_commits[filenum].keys.each do |commit|
      unless commit_list.include?(commit)
        commit_list << commit
      end
    end
  end

  commit_list.each do |commit|
    message_short = ""
    hash_array = []
    filenums_with_tests = 0
    filenums.each do |filenum|
      filenums_commits[filenum][commit] ||= {tests: []}
      if filenums_commits[filenum][commit][:tests].empty?
        hash_array << "N/A"
      else
        filenums_with_tests += 1
        hash_array << "✓".colorize(:green)
        message_short = filenums_commits[filenum][commit][:message_short]
      end
    end
    unless filenums_with_tests > 1
      diff_table << [commit, hash_array, message_short, "missing", Array.new(filenums.length, "")].flatten
      next
    end
    tests_missing = []
    filenums.each do |filenum|
      data = filenums_commits[filenum][commit]
      tests.each do |test|
        found = data[:tests].find { |t| t[:name] == test }
        if found.nil?
          tests_missing << filenum
        end
      end
    end

    matchfail = []
    results = []
    tests.each do |test|
      results = []
      filenums.each do |filenum|
        data = filenums_commits[filenum][commit]
        found = data[:tests].find { |t| t[:name] == test }
        found = {result: "N/A"} if found.nil?
        results << found[:result]
      end
      if results.uniq.length != 1
        matchfail << test
        diff_table << [
          commit,
          hash_array,
          message_short,
          test.colorize(:red),
          results
        ].flatten
      end
    end
    verdict_list = []
    ["OS-LTS", "OS-LTS-SEC", "OS-LTS-KLP", "OS-LTS-KLP-SEC"].each do |v|
      verdict_list << v.colorize(:green) if filenums_commits[0][commit][v] == "true".colorize(:green)
    end
    if matchfail.empty?
      row = [
        commit,
        hash_array,
        message_short,
        "results_match".colorize(:green),
        Array.new(filenums.length, "✓".colorize(:green))
      ].flatten
      diff_table << row.concat(verdict_list) unless verdict_list.empty?
      diff_table << row
    end
  end
  puts diff_table
end

exit 0 unless apply

repo = '/home/snajpa/linux'
save_branch = `git rev-parse --abbrev-ref HEAD`.strip

puts

aborted = {"OS-LTS" => [], "OS-LTS-KLP" => [], "OS-LTS-KLP-SEC" => []}

Dir.chdir(repo) do
  `git cherry-pick --abort 2>&1 > /dev/null`
  `git checkout -f #{to_branch}`
  `git pull`

  target_branches = {
    "OS-LTS-KLP-SEC" => "#{to_branch}-lts-klp-sec",
    "OS-LTS-KLP" => "#{to_branch}-lts-klp",
    "OS-LTS" => "#{to_branch}-lts",
  }

  target_branches.each do |verdict, branch|
    branch_start_time = Time.now
    `git branch -D #{branch}`
    `git checkout -b #{branch}`
    commit_n = 0
    success_n = 0
    commits.each do |commit, data|
      commit_n += 1
      elapsed = Time.now - branch_start_time
      progress = (commit_n.to_f / commits.length.to_f * 100).round(2)
      if elapsed > 3 && progress % 5 == 0
        print format("\r%s %2d/%2d elapsed %3.2fs done %2d%%",
          branch, commit_n, commits.length, elapsed, progress)
        $stdout.flush
      end
      next if data.nil? || data[:tests].nil?
      next if data[verdict] != "true".colorize(:green)
      result = `git cherry-pick #{commit} 2>&1`
      data[:cherry_pick_result] = result.lines
      #puts result
      exitstatus = $?.exitstatus
      if exitstatus != 0
        `git cherry-pick --abort`
        #puts "RESULT LINES: #{result.lines}"
        next if result.lines.last =~ /working tree clean/

        # get the full commit message
        result = `git show --no-patch --format=%B #{commit}`
        data[:message] = result

        if !data[:broken_in_this_branch] && match = data[:message].match(/fixes:\s+([a-f0-9]{6,})/i)
          hash = match.captures.first
          `git merge-base --is-ancestor #{hash} #{to_branch}`
          if $?.exitstatus != 0
            data[:broken_in_this_branch] = false
          else
            data[:broken_in_this_branch] = true
          end
        end
        aborted[verdict] << [commit, data]
      end
      success_n += 1
    end
    puts format("\n%s: %d successful, %d failed cherry-picks", branch, success_n, aborted[verdict].length)
  end
end

table_aborted = Terminal::Table.new do |t|
  t.headings = ['verdict', 'commit', 'msg', 'broken_in_this_branch']
  t.style = { :border_left => false, :border_right => false }
end

def word_wrap(text, line_width = 100 ) 
  return text if line_width <= 0
  text.gsub(/(.{1,#{line_width}})(\s+|\Z)/, "\\1\n")
end

prev_verdict = nil
aborted.each do |verdict, commits|
  commits.each do |commit_array|
    commit, data = commit_array
    verdict = verdict unless prev_verdict == verdict
    prev_verdict = verdict
    if data[:broken_in_this_branch].nil?
      broken_in_this_branch = "N/A"
    elsif data[:broken_in_this_branch]
      broken_in_this_branch = "true".colorize(:red)
    else
      broken_in_this_branch = "false".colorize(:green)
    end
    table_aborted.add_separator unless table_aborted.rows.empty?
    table_aborted.add_row [verdict, commit, data[:message_short], broken_in_this_branch]
    table_aborted.add_row ["", "", "\n" + word_wrap(data[:cherry_pick_result].join("\n\n")), ""]
  end
end

puts
puts table_aborted
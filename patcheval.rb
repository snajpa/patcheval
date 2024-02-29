#!/usr/bin/env ruby

require 'si'
require 'rugged'
require 'net/http'
require 'json'
require 'erb'
require 'csv'
require 'fileutils'

# cmake .. -DLLAMA_CUBLAS=ON -DCMAKE_CUDA_ARCHITECTURES="80;86" -DLLAMA_CUDA_MMV_Y=1 -DLLAMA_CUDA_DMMV_X=4096 -DCMAKE_BUILD_TYPE=Release -DLLAMA_CUDA_PEER_MAX_BATCH_SIZE=1024
# llama.cpp/build$ ./bin/server -m ~/models/miqu-1-70b/miqu-1-70b.q4_k_m.gguf -ts 10,13 -ngl 99 --mlock -b 1024 -mg 1 -c 4096

tests = {
  'bug-01' => {
    ok_regex: /BUGFIX/,
    fail_regex: /NOT/,
    patch_part_policy: 'OR', # OR or AND
    repair_prompt: "Outcome: (BUGFIX/NOT):",
    options: { n_predict: 150, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.6, seed: 42 }
  },
  'stable-01' => {
    ok_regex: /BACKPORT/,
    fail_regex: /SKIP/,
    patch_part_policy: 'OR', # OR or AND
    repair_prompt: "Invalid response, reply 'BACKPORT' or 'SKIP', backport to stable:",
    options: { n_predict: 5, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.6, seed: 42 }
  },
  'security-01' => {
    ok_regex: /YES/,
    fail_regex: /NO/,
    patch_part_policy: 'OR', # OR or AND
    repair_prompt: "Invalid response, reply 'YES' or 'NO':",
    options: { n_predict: 5, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.6, seed: 42 }
  },
  'kpatch-build-01' => {
    ok_regex: /COMPLIANT=YES/,
    fail_regex: /COMPLIANT=NO/,
    patch_part_policy: 'AND', # OR or AND
    repair_prompt: 'Incomplete response, reply must contain explicit COMPLIANT=YES or COMPLIANT=NO:',
    options: { n_predict: 5, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.4, seed: 42 }
  },
  'kpatch-build-02' => {
    ok_regex: /COMPLIANT=YES/,
    fail_regex: /COMPLIANT=NO/,
    patch_part_policy: 'AND', # OR or AND
    repair_prompt: 'Invalid response, reply COMPLIANT=YES or COMPLIANT=NO, no other response is valid:',
    options: { n_predict: 8, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.6, seed: 42 }
  },
  'commit-summary' => {
    options: { n_predict: 500, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.7, seed: 42 }
  },
  'vpsadminos-01' => {
    ok_regex: /ACCEPT/,
    fail_regex: /IGNORE/,
    patch_part_policy: 'OR', # OR or AND
    repair_prompt: "Conclusion 'ACCEPT'/'IGNORE' (retry %d/%d):",
    options: { n_predict: 100, repeat_penalty: 1.1, repeat_last_n: 64, temperature: 0.6, seed: 42 }
  },
}

#plan = ["bug-01"]
#plan = ["vpsadminos-01"]
plan = ["bug-01", "stable-01", "vpsadminos-01", "security-01", "kpatch-build-02"]
#plan = ["kpatch-build-01"]
#plan = ["commit-summary", "vpsadminos-01"]
skip_commit_on_consecutive_fails = false

results = {}
start_time = Time.now

# Create log directory with UTF format of current time
dir = Time.now.strftime('%Y-%m-%d_%H-%M-%S_%Z')
log_dir = File.join('./logs', dir)
FileUtils.mkdir_p(log_dir)
log_file = File.join(log_dir, 'log.txt')
$logf = File.open(log_file, 'a+')
$logf.sync = true
$csvf = File.open(File.join(log_dir, 'log.csv'), 'a+')
$csvf.sync = true

# Update symlinkgs in logs directory, so that the latest logs are always available
# in _latest and _previous
FileUtils.rm_f('./logs/_previous')
FileUtils.mv('./logs/_latest', './logs/_previous') if File.exist?('./logs/_latest')
FileUtils.ln_s(dir, './logs/_latest')

def log(message)
  $logf.puts message
  puts message
end

def logn(message)
  $logf.print message
  print message
end

def log_verbose(message)
  $logf.puts message
end

def log_csv(a)
  message = a.to_csv
  $csvf.puts message
  log_verbose(message)
end

class PromptGenerator
  def initialize(test_file)
    @test = File.read("prompts/#{test_file}.erb")
  end

  def generate(params)
    @params = params
    ERB.new(@test).result(binding)
  end
end

class Spinner
  def initialize
    # @spinner_chars = ['⣾','⣽','⣻','⢿','⡿','⣟','⣯','⣷']
    @spinner_chars = ['⠁', '⠂', '⠄', '⡀', '⡈', '⡐', '⡠', '⣀',
                      '⣁', '⣂', '⣄', '⣌', '⣔', '⣤', '⣥', '⣦',
                      '⣮', '⣶', '⣷', '⣿', '⡿', '⠿', '⢟', '⠟',
                      '⡛', '⠛', '⠫', '⢋', '⠋', '⠍', '⡉', '⠉',
                      '⠑', '⠡', '⢁']
    @index = 0
    @running = false
    @printed = 0
    @thread = nil
  end

  def start(length = 1)
    return if @running

    @running = true
    @thread = Thread.new do
      loop do
        break unless @running

        @printed = length
        length.times { print "#{@spinner_chars[@index]}" }
        @index = (@index + 1) % @spinner_chars.length
        sleep 0.08
        @printed.times { print "\b" }
        @printed = 0
      end
    end
  end

  def stop
    return unless @running

    @running = false
    @thread.join if @thread
    @printed.times { print "\b" }
    @printed = 0
  end
end
spinner = Spinner.new


Signal.trap('INT') do
  spinner.stop
  puts
  exit 1
end
Signal.trap('TERM') do
  spinner.stop
  puts
  exit 1
end

# Replace these with the paths to your repository and the tags you want to walk between
repo_path = '/home/snajpa/linux'

start_ref, end_ref = ARGV

unless start_ref
  puts 'Error: Please provide start and end refs/tags/branches/commits.'
  puts 'Usage: patcheval <start_ref> [<end_ref>] [resume <resume_file>]'
  exit(1)
end

ARGV.shift
ARGV.shift unless end_ref.nil?
end_ref ||= start_ref

resume = ARGV[0] == 'resume'
resume_file = ARGV[1]

if resume
  unless resume_file
    puts 'Error: Please provide resume file.'
    puts 'Usage: patcheval <start_ref> [<end_ref>] resume <resume_file>'
    exit(1)
  end
  resume_csv = CSV.read(resume_file)
  resume_csv.each do |row|
    skip_commits << row[0]
    log_csv row
  end
end
skip_commits = []


def find_commit(repo, user_input)
  # Attempt to resolve commit directly from SHA or through references
  commit = nil
  begin
    # Direct SHA lookup
    commit = repo.lookup(user_input)
  rescue Rugged::InvalidError
    # If direct lookup fails, attempt to find matching reference (branch or tag)
    repo.references.each do |ref|
      next unless ref.name.end_with?(user_input) || ref.target == user_input

      target = ref.target
      commit = repo.lookup(target.is_a?(String) ? target : ref.target_id)
      break
    end
  rescue Rugged::ReferenceError
    puts 'Input does not correspond to a valid commit, tag, or branch.'
  end
  commit
end

repo = Rugged::Repository.new(repo_path)

start_commit = find_commit(repo, start_ref)
end_commit = find_commit(repo, end_ref)

start_commit = start_commit.parents.first if start_commit == end_commit

walker = Rugged::Walker.new(repo)
walker.sorting(Rugged::SORT_DATE)
walker.push(end_commit)
walker.hide(start_commit)

log "patcheval.rb: Walking between #{start_ref} and #{end_ref}"
log "Start commit: #{start_commit.oid}"
log "End commit:   #{end_commit.oid}"
log 'Walk started at:'
log "\t#{Time.now.utc}"
log "\t#{Time.now.localtime}"
log "Commit test plan: #{plan.join(', ')}"
log "Skip commit on consecutive fails: #{skip_commit_on_consecutive_fails}"
log ''

commits = []
logn 'Total commits: '
spinner.start 5
commit_count = 0
walker.each do |commit|
  next if commit.parents.size > 1 # Skip merge commits with no diff
  next if resume && skip_commits.include?(commit.oid)
  commit_count += 1
  commits << commit
end
spinner.stop
log commit_count
log ''

def response_ok?(response, ok_regex, fail_regex)
  raise 'Response matches both OK and FAIL regex' if response =~ ok_regex && response =~ fail_regex

  if response =~ ok_regex
    true
  elsif response =~ fail_regex
    false
  else
    raise "Unexpected response: #{response}"
  end
end

commit_n = 0
total_timings = {'prompt_n' => 0, 'prompt_per_second' => 0, 'predicted_n' => 0, 'predicted_per_second' => 0}
eta = 0
commits.each do |commit|
  test_n = 0
  commit_n += 1
  results[commit.oid] = { skipped: true, prompts: {} }

  fails = 0
  log '%s, %3d/%d,  ETA %s, %s %s' % [Time.now.localtime, commit_n, commit_count, Time.at(Time.now + eta),
             commit.oid, commit.message.lines.first.chomp]

  response_first = ''
  response = ''
  plan.each do |test_name|
    test_n += 1
    test = tests[test_name]
    raise "Test not found: #{test_name}" if test.nil?

    starting = Time.now
    log_verbose "\n"
    logn format(' test: %20s', "#{test_name} ")
    spinner.start 12
    prompt_generator = PromptGenerator.new(test_name)
    ok = test[:patch_part_policy] == 'AND'
    diff = commit.diff
    patch_s = ''
    diff.each_patch do |patch|
      patch_s += patch.to_s + "\n"
    end
    prompts_length = 0
    responses_length = 0
    prompt = prompt_generator.generate({ diff: patch_s.force_encoding('UTF-8'),
                                         commit: commit.oid,
                                         message_short: commit.message.lines.first.chomp.force_encoding('UTF-8'),
                                         message: commit.message.force_encoding('UTF-8'),
                                         plan_response_prev: response.force_encoding('UTF-8'),
                                         plan_response_first: response_first.force_encoding('UTF-8') })
    retries = 0
    timings = {}
    per_test_timings = {}
    n_predict = test[:options][:n_predict]
    seed = test[:options][:seed].nil? ? 42 : test[:options][:seed]
    begin
      log_verbose "\n#{commit.oid},#{test_name},prompt\n" + prompt
      url = URI.parse('http://localhost:8080/completion')
      http = Net::HTTP.new(url.host, url.port)
      request = Net::HTTP::Post.new(url.path)
      request.content_type = 'application/json'
      request.body = test[:options].merge({ prompt: prompt,
                                            stream: false,
                                            n_predict: n_predict,
                                            seed: seed}).to_json
      request_result = http.request(request)
      result = JSON.parse(request_result.body)
      #log_verbose JSON.pretty_generate(result)
      response = result['content']
      #puts "===RESPONSE===\n" + response + "\n===/RESPONSE===\n"
      response_first = response if test_n == 1
      #context = result['context']
      timings = result['timings']
      ['prompt_n', 'prompt_per_second', 'predicted_n', 'predicted_per_second'].each do |key|
        total_timings[key] = (total_timings[key].nil? ? 0 : total_timings[key]) + timings[key]
        per_test_timings[key] = (per_test_timings[key].nil? ? 0 : per_test_timings[key]) + (timings[key].nil? ? 0 : timings[key])
      end
      log_verbose "#{commit.oid},#{test_name},response\n" + response + "\n\n"
      unless test[:ok_regex].nil? || test[:fail_regex].nil?
        ok = if test[:patch_part_policy] == 'AND'
               ok && response_ok?(response, test[:ok_regex], test[:fail_regex])
             else
               ok || response_ok?(response, test[:ok_regex], test[:fail_regex])
             end
      end
    rescue RuntimeError
      retries += 1
      log_verbose "Retrying... (#{retries}/5)"
      seed = seed + 1
      prompt += "%s\n" % response
      prompt += test[:repair_prompt] % [retries, 10]
      prompt += "\n"
      n_predict = [1000, [100, n_predict].min * retries].max
      if retries < 10
        retry
      else
        log_verbose 'Too many retries, skipping commit'
        ok = nil
      end
      rescue EOFError
        sleep 5
        retry
      rescue JSON::ParserError
        sleep 5
        retry
      rescue Errno::ECONNREFUSED
        sleep 5
        retry
      rescue Errno::ECONNRESET
        sleep 5
        retry
    end
    spinner.stop
    res = 'unknown'
    if ok == true
      res = 'ok'
    elsif ok == false
      res = 'fail'
    end
    res = '%5d long' % response.length if test[:ok_regex].nil? && test[:fail_regex].nil?
    ending = Time.now
    elapsed = ending - starting
    running_time = ending - start_time
    eta = running_time / commit_n * (commit_count - commit_n)
    logn " %10s " % res
    logn "%5.2fs" % elapsed
    logn "    in %5d t" % (per_test_timings['prompt_n'].nil? ? 0 : per_test_timings['prompt_n'])
    logn " %7.2f t/s" % (per_test_timings['prompt_per_second'].nil? ? 0 : per_test_timings['prompt_per_second'])
    logn "    out %5d t" % (per_test_timings['predicted_n'].nil? ? 0 : per_test_timings['predicted_n'])
    logn " %7.2f t/s" % (per_test_timings['predicted_per_second'].nil? ? 0 : per_test_timings['predicted_per_second'])
    logn "    avg %7.2f t/s" % ((total_timings['prompt_n'] + total_timings['predicted_n']) / (running_time))
    logn " tot %5st in %5st out\n" % [total_timings['prompt_n'].si, total_timings['predicted_n'].si]
    log_csv [commit.oid, commit.message.lines.first.chomp, test_name, res, per_test_timings['prompt_n'], per_test_timings['predicted_n'], elapsed]
    results[commit.oid][:prompts][test_name] = { result: res, elapsed: elapsed }
    fails = 0 if !!skip_commit_on_consecutive_fails && ok && !test[:ok_regex].nil? && !test[:fail_regex].nil?
    next unless !!skip_commit_on_consecutive_fails && !ok && !test[:ok_regex].nil? && !test[:fail_regex].nil?

    fails += 1
    if fails >= skip_commit_on_consecutive_fails
      log_verbose 'Skipping commit due to consecutive fails'
      break
    end
  end
  results[commit.oid][:skipped] = false
  log_verbose "\n=====\n\n"
end

# Update symlinkgs in logs directory, so that the latest logs are always available
# in _latest and _previous
FileUtils.rm_f('./logs/_previous_complete')
FileUtils.mv('./logs/_latest_complete', './logs/_previous_complete') if File.exist?('./logs/_latest_complete')
FileUtils.ln_s(dir, './logs/_latest_complete')

#!/usr/bin/env ruby

require 'optparse'
require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
require 'yaml'

# Guenther's runtime configuration
class Configuration
  CONFIG_FILE = 'guenther.yaml'.freeze

  attr_accessor :category, :language, :level, :number_of_questions,
                :show_answer, :timeout
  attr_accessor :jid, :password, :room
  attr_reader :debug

  def initialize
    @category = 'all'
    @debug = false
    @level = 'all'
    @language = 'all'
    @number_of_questions = 10
    @show_answer = false
    @timeout = 60

    @jid = ''
    @password = ''
    @room = ''
  end

  def to_s
    <<-EOT.chomp
Configuration:
  category: #{@category}
  debug: #{@debug}
  level: #{@level}
  language: #{@language}
  number_of_questions: #{@number_of_questions}
  show_answer: #{@show_answer}
  timeout: #{@timeout}
    EOT
  end

  def debug=(value)
    @debug = value
    Jabber.debug = @debug
  end

  def to_h
    instance_variables.map do |var|
      # Map symbol strings to strings without the @ sign and the corresponding
      # value
      [var[1..-1], instance_variable_get(var)]
    end.to_h
  end

  def save
    File.open(CONFIG_FILE, 'w') do |file|
      file.write to_h.to_yaml
    end
  end

  def load
    config = YAML.load_file(CONFIG_FILE)
    config.each do |k, v|
      instance_variable_set("@#{k}", v)
    end
  rescue Errno::ENOENT => e
    STDERR.puts "Could not load config from #{CONFIG_FILE}: #{e}"
  end
end

# Questionpool contains all the questions and related function
class Questionpool
  def initialize
    @questions = []
  end

  def get(language, category, level)
    questions = @questions.select do |q|
      (language == 'all' || q['Language'] == language) &&
        (category == 'all' || q['Category'] == category) &&
        (level == 'all' || q['Level'] == level) &&
        !q['used']
    end

    if questions.empty?
      reset_used_questions
      return get(language, category, level)
    end

    question = questions.sample
    question['used'] = true
    question
  end

  def any_key_has_value?(key, value)
    return true if value == 'all'

    @questions.any? { |q| q[key] == value }
  end

  def load
    cur_question = nil

    Dir.glob('quizdata/*.utf8') do |filename|
      language = filename.split('.')[-2]
      File.open(filename).each_line do |line|
        next if line.start_with?('#')

        if line == "\n"
          if cur_question
            @questions.push(cur_question)
            cur_question = nil
          end
        else
          cur_question ||= { 'used' => false,
                             'Language' => language }
          linesplit = line.split(': ', 2)
          cur_question[linesplit.first.strip] = linesplit.last.strip
        end
      end
    end
  end

  def number_of_questions_per(key)
    counts = Hash.new(0)
    @questions.each do |q|
      v = q[key]
      counts[v] += 1 if v
    end

    # Sort the above hash by key, this turns it into an array of arrays.
    # Map the outer array to an array of strings and join them with a comma.
    counts.sort.map { |e| "#{e[0]} (#{e[1]})" }.join(', ')
  end

  private

  def reset_used_questions
    @questions.each do |question|
      question['used'] = false
    end
  end
end

# The main class implementing the XMPP quiz bot
class Guenther
  HELP_TEXT = <<-EOT.chomp.freeze
Usage:
  startquiz [number of questions]: start a quiz
  stopquiz: stops the current quiz
  next: move to the next question
  scoreboard: show the last score board
  categories: show all available categories
  languages: show all available languages
  config: show the current config
  set <option> <value>: set a config value
  save: save current config to file
  load: load config from file
  exit: exit
  help: show this help text
  EOT

  def initialize
    @config = Configuration.new
    @config.load

    @current_question = nil
    @remaining_questions = 0
    @scoreboard = Hash.new(0)

    parse_options

    @questionpool = Questionpool.new
    @questionpool.load
  end

  # rubocop:disable Metrics/AbcSize
  def parse_options
    optparse = OptionParser.new do |opts|
      opts.banner = "Usage: #{$PROGRAM_NAME} [options]"

      opts.on('-j', '--jid JID', 'Jabber identifier') do |j|
        @config.jid = j
      end

      opts.on('-p', '--password PASSWORD', 'Password') do |p|
        @config.password = p
      end

      opts.on('-r', '--room ROOM',
              'Multi-user chat room (room@conference.example.com/nick)') do |r|
        @config.room = r
      end

      opts.on('-d', '--debug', 'Enables XMPP debug logging') do
        @config.debug = true
      end

      opts.on('-h', '--help', 'Prints this help message') do
        puts opts
        exit 1
      end
    end

    begin
      optparse.parse!
      # TODO: Look at this, will it point out the missing argument?
      raise OptionParser::MissingArgument if @config.jid.empty?
      raise OptionParser::MissingArgument if @config.password.empty?
      raise OptionParser::MissingArgument if @config.room.empty?
    rescue
      puts optparse
      exit 1
    end
  end
  # rubocop:enable Metrics/AbcSize

  def ask_question
    @current_question = @questionpool.get(@config.language, @config.category,
                                          @config.level)
    @current_question['timeout'] = Time.now + @config.timeout
    if @current_question['Category']
      say "[#{@current_question['Category']}] #{@current_question['Question']}"
    else
      say @current_question['Question']
    end
  end

  def answer_question
    regex = @current_question['Regexp']
    say regex if regex && @config.debug
    say @current_question['Answer'].delete('#') if @config.show_answer
  end

  def handle_answer(nick, text)
    regex = @current_question['Regexp']
    answered = if regex
                 # Compare answer to the regex if we have one
                 /#{regex}/i =~ text
               else
                 text.casecmp(@current_question['Answer'].delete('#')) == 0
               end

    if answered
      say "Correct answer #{nick}!"
      @scoreboard[nick] += 1
      @remaining_questions -= 1
      if @remaining_questions > 0
        ask_question
      else
        stop_quiz
      end
    end
  end

  def say_number_of_questions_per(key)
    say @questionpool.number_of_questions_per(key)
  end

  def say_scoreboard
    scoreboard = "(.•ˆ•… Scoreboard …•ˆ•.)"
    @scoreboard.each do |nick, score|
      scoreboard += "\n#{nick}: #{score}"
    end
    say scoreboard
  end

  def me
    @muc_client.jid.resource
  end

  def talking_to_me?(text)
    text.start_with? "#{me}:"
  end

  def extract_command(text)
    text.match(/^#{me}: (\S+) ?(.*)?/)[1..2]
  end

  def start_quiz(parameter)
    if @current_question
      say 'Quiz already running'
      return
    end

    if parameter.empty?
      @remaining_questions = @config.number_of_questions
    else
      begin
        @remaining_questions = Integer(parameter)
      rescue ArgumentError
        say "Invalid number of questions: #{parameter}"
        return
      end
    end

    @scoreboard.clear
    ask_question

    # Thread to handle question timeouts
    Thread.new do
      while @current_question
        # XXX this crashes at the end of the quiz because @current_question
        # will be set to nil
        sleep 1 while Time.now < @current_question['timeout']
        answer_question
        ask_question
      end
    end
  end

  def stop_quiz
    if @current_question
      say_scoreboard
      @current_question = nil
    else
      say 'No quiz is running'
    end
  end

  def say(text)
    @muc_client.say text
  end

  def handle_next
    if @current_question
      answer_question
      ask_question
    else
      say 'No quiz is running'
    end
  end

  def handle_save
    @config.save
  end

  def handle_load
    @config.load
  end

  def say_config
    say @config.to_s
  end

  # rubocop:disable Style/AccessorMethodName
  def set_if_available(key, value)
    if @questionpool.any_key_has_value?(key, value)
      @config.send(key.downcase + '=', value)
    else
      say 'Could not find any matching questions'
    end
  end

  def set_timeout(value)
    timeout = Integer(value)
    @config.timeout = timeout
  rescue ArgumentError => e
    say "Could not set timeout: #{e}"
  end

  def set_number_of_questions(value)
    @config.number_of_questions = Integer(value)
  rescue ArgumentError => e
    say "Could not set number_of_questions: #{e}"
  end
  # rubocop:enable Style/AccessorMethodName

  def setup
    jid = Jabber::JID.new(@config.jid)
    @client = Jabber::Client.new(jid)
    @client.connect
    @client.auth(@config.password)
    @muc_client = Jabber::MUC::SimpleMUCClient.new(@client)
    @muc_client.join(@config.room)

    @mainthread = Thread.current
  end

  def wait_and_shutdown
    Thread.stop
    @muc_client.exit 'Goodbye.'
    @client.close
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def handle_set(parameter)
    matches = parameter.match(/(\S+) (\S+)/)
    unless matches
      say 'Invalid option/value'
      return
    end
    value = matches[2]

    case matches[1]
    when 'category'
      set_if_available('Category', value)
    when 'language'
      set_if_available('Language', value)
    when 'number_of_questions'
      set_number_of_questions value
    when 'show_answer'
      @config.show_answer = value == 'true'
    when 'timeout'
      set_timeout value
    when 'debug'
      @config.debug = value == 'true'
    when 'level'
      set_if_available('Level', value)
    else
      say 'Unknown option'
    end
  end

  def dispatch(command, parameter)
    case command
    when 'startquiz'
      start_quiz parameter
    when 'stopquiz'
      stop_quiz
    when 'next'
      handle_next
    when 'scoreboard'
      say_scoreboard
    when 'categories'
      say_number_of_questions_per 'Category'
    when 'languages'
      say_number_of_questions_per 'Language'
    when 'config'
      say_config
    when 'set'
      handle_set parameter
    when 'save'
      handle_save
    when 'load'
      handle_load
    when 'exit'
      @mainthread.wakeup
    when 'help'
      say HELP_TEXT
    else
      say 'Unknown command, try help'
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def run
    setup

    @muc_client.on_message do |time, nick, text|
      # Avoid reacting on messages delivered as room history
      next if time

      # Look at every line if we have a question in flight and we
      # didn't say it
      handle_answer nick, text if @current_question && nick != me

      # Nothing to do if the line is not addressed to us
      next unless talking_to_me? text

      command, parameter = extract_command(text)
      dispatch command, parameter
    end

    wait_and_shutdown
  end
end

if __FILE__ == $PROGRAM_NAME
  guenther = Guenther.new
  guenther.run
end

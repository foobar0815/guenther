#!/usr/bin/env ruby

require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
require 'yaml'

class Guenther
  CONFIG_FILE = 'guenther.yaml'

  attr_accessor :jid, :password, :room, :questionpool

  def try_load_config
    return false unless File.readable? CONFIG_FILE
    config = YAML.load_file(CONFIG_FILE)
    # config will be false if the file was empty
    return false unless config

    @jid = config['jid']
    @password = config['password']
    @room = config['room']
    true
  end

  def initialize
    return if try_load_config

    if ARGV.size != 3
      STDERR.puts "Usage: #{$0} <jid> <password> <room@conference.example.com/nick>"
      exit 1
    end
    @jid = ARGV[0]
    @password = ARGV[1]
    @room = ARGV[2]
  end

  def load_questions
    @questionpool = []

    cur_question = nil
    Dir.glob('quizdata/*.utf8') do |filename|
      File.open(filename).each_line do |line|
        next if line.start_with?('#')

        if line == "\n"
          if cur_question
            @questionpool.push(cur_question)
            cur_question = nil
          end
        else
          cur_question ||= {}
          linesplit = line.split(": ", 2)
          cur_question[linesplit.first.strip] = linesplit.last.strip
        end
      end
    end
  end
end

guenther = Guenther.new
guenther.load_questions

#Jabber::debug = true
cl = Jabber::Client.new(Jabber::JID.new(guenther.jid))
cl.connect
cl.auth(guenther.password)

# For waking up...
mainthread = Thread.current

# This is the SimpleMUCClient helper!
m = Jabber::MUC::SimpleMUCClient.new(cl)

# SimpleMUCClient callback-blocks

m.on_message do |time,nick,text|
  # Avoid reacting on messaged delivered as room history
  unless time
    # Bot: startquiz
    if text.strip =~ /^(.+?): startquiz ([0-9]|[0-9]{2})$/
      if $1.downcase == m.jid.resource.downcase
        if $2
          $question = guenther.questionpool.sample
          $question["lifetime"] = Time.now + 60
          m.say($question["Question"])
          Thread.new do
            while $question
              while Time.now < $question["lifetime"]
                sleep 1
              end
              $question = guenther.questionpool.sample
              $question["lifetime"] = Time.now + 60
              m.say($question["Question"])
            end
          end
          $questioncount = $2.to_i - 1
          $scoreboard = Hash.new
        end
      end
    # Bot: next
    elsif text.strip =~ /^(.+?): next$/
      if $question
        $question = guenther.questionpool.sample
        $question["lifetime"] = Time.now + 60
        m.say($question["Question"])
      else
        m.say("No quiz has been started!")
      end
    # Bot: exit
    elsif text.strip =~ /^(.+?): exit$/
      if $1.downcase == m.jid.resource.downcase
        m.exit "Exiting on behalf of #{nick}"
        mainthread.wakeup
      end
    # look for anything if a question was asked
    elsif $question
      if $question["Regexp"]
        if /#{$question["Regexp"]}/ =~ text
          answered = true
        end
      elsif text.casecmp($question["Answer"]) == 0
        answered = true
      end
      if answered == true
        m.say("Correct answer #{nick}!")
        if $scoreboard.has_key?(nick)
          $scoreboard[nick] = $scoreboard[nick] + 1
        else
          $scoreboard[nick] = 1
        end
        if $questioncount > 0
          $question = guenther.questionpool.sample
          $question["lifetime"] = Time.now + 60
          m.say($question["Question"])
          $questioncount = $questioncount-1
        else
          $question = nil
          m.say("(.•ˆ•… Scoreboard …•ˆ•.)")
          $scoreboard.each do |key, val|
            m.say("#{key}: #{val}")
          end
        end
      end
    end
  end
end

m.join(guenther.room)

# Wait for being waken up by m.on_message
Thread.stop

cl.close

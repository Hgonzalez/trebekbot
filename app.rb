# encoding: utf-8
require "sinatra"
require "json"
require "httparty"
require "redis"
require "dotenv"
require "text"
require "sanitize"

configure do
  # Load .env vars
  Dotenv.load
  # Disable output buffering
  $stdout.sync = true
  
  # Set up redis
  case settings.environment
  when :development
    uri = URI.parse(ENV["LOCAL_REDIS_URL"])
  when :production
    uri = URI.parse(ENV["REDISCLOUD_URL"])
  end
  $redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
end

# params:
# token=abc123
# team_id=T0001
# channel_id=C123456
# channel_name=test
# timestamp=1355517523.000005
# user_id=U123456
# user_name=Steve
# text=trebekbot jeopardy me
# trigger_word=trebekbot
post "/" do
  params[:text] = params[:text].sub(params[:trigger_word], "").strip 
  if params[:token] != ENV["OUTGOING_WEBHOOK_TOKEN"]
    response = "Invalid token"
  elsif params[:text].match(/^jeopardy me/i)
    response = send_question(params)
  elsif params[:text].match(/my score$/i)
    response = get_user_score(params)
  elsif params[:text].match(/^help$/i)
    response = get_help
  else
    response = process_answer(params)
  end

  status 200
  body response
end

def get_question
  uri = "http://jservice.io/api/random?count=1"
  request = HTTParty.get(uri)
  response = JSON.parse(request.body).first
  if response["question"].nil? || response["question"].strip == ""
    response = get_question
  end
  response
end

def send_question(params)
  response = get_question
  response["value"] = 100 if response["value"].nil?
  key = "current_question:#{params[:channel_id]}"
  question = ""
  previous_question = $redis.get(key)
  if !previous_question.nil?
    previous_question = Sanitize.fragment(JSON.parse(previous_question)["answer"])
    question = "The answer is `#{previous_question}`. Moving on… "
  end
  question += "The category is `#{response["category"]["title"]}` for $#{response["value"]}: `#{response["question"]}`"
  puts "[LOG] ID: #{response["id"]} | Category: #{response["category"]["title"]} | Question: #{response["question"]} | Answer: #{response["answer"]} | Value: #{response["value"]}"
  $redis.set(key, response.to_json)
  json_response_for_slack(question)
end

def process_answer(params)
  key = "current_question:#{params[:channel_id]}"
  current_question = $redis.get(key)
  if current_question.nil?
    reply = trebek_me
  else
    current_question = JSON.parse(current_question)
    current_answer = current_question["answer"]
    user_answer = params[:text]
    if is_question_format?(user_answer) && is_correct_answer?(current_answer, user_answer)
      score = update_score(params[:user_id], current_question["value"])
      reply = "That is the correct answer, #{get_slack_name(params[:user_id], params[:user_name])}. Your total score is #{format_score(score)}."
      $redis.del(key)
    elsif is_correct_answer?(current_answer, user_answer)
      score = update_score(params[:user_id], (current_question["value"] * -1))
      reply = "That is correct, #{get_slack_name(params[:user_id], params[:user_name])}, but responses have to be in the form of a question. Your total score is #{format_score(score)}."
      $redis.del(key)
    else
      score = update_score(params[:user_id], (current_question["value"] * -1))
      reply = "Sorry, #{get_slack_name(params[:user_id], params[:user_name])}, the correct answer is `#{Sanitize.fragment(current_question["answer"])}`. Your score is now #{format_score(score)}."
      $redis.del(key)
    end
  end
  json_response_for_slack(reply)
end

def is_question_format?(answer)
  answer.gsub(/[^\w\s]/i, "").match(/^(what|whats|where|wheres|who|whos) /i)
end

def is_correct_answer?(correct, answer)
  correct = Sanitize.fragment(correct)
  correct = correct.gsub(/[^\w\s]/i, "").gsub(/^(the|a|an) /i, "").strip.downcase
  answer = answer.gsub(/[^\w\s]/i, "").gsub(/^(what|whats|where|wheres|who|whos) /i, "").gsub(/^(is|are|was|were) /, "").gsub(/^(the|a) /i, "").gsub(/\?+$/, "").strip.downcase
  white = Text::WhiteSimilarity.new
  similarity = white.similarity(correct, answer)
  puts "[LOG] Correct answer: #{correct} | User answer: #{answer} | Similarity: #{similarity}"
  similarity >= 0.5
end

def get_user_score(params)
  key = "user_score:#{params[:user_id]}"
  user_score = $redis.get(key)
  if user_score.nil?
    $redis.set(key, 0)
    user_score = 0
  end
  reply = "#{get_slack_name(params[:user_id], params[:user_name])}, your score is #{format_score(user_score.to_i)}."
  json_response_for_slack(reply)
end

def update_score(user_id, score = 0)
  key = "user_score:#{user_id}"
  user_score = $redis.get(key)
  if user_score.nil?
    $redis.set(key, score)
    score
  else
    $redis.set(key, user_score.to_i + score)
    user_score.to_i + score
  end
end

def format_score(score)
  if score >= 0
    "$#{score}"
  else
    "-$#{score * -1}"
  end
end

def get_slack_name(user_id, username)
  if ENV["API_TOKEN"].nil?
    name = username
  else
    key = "user_names:#{user_id}"
    name = $redis.get(key)
    if name.nil?
      uri = "https://slack.com/api/users.list?token=#{ENV["API_TOKEN"]}"
      request = HTTParty.get(uri)
      response = JSON.parse(request.body)
      if response["ok"]
        user = response["members"].find { |u| u["id"] == user_id }
        name = user["profile"]["first_name"].nil? ? username : user["profile"]["first_name"]
      else
        name = username
      end
      $redis.setex(key, 3600, name)
    end
  end
  name
end

def trebek_me
  responses = [ "Welcome back to Slack Jeopardy. Before we begin this Jeopardy round, I'd like to ask our contestants once again to please refrain from using ethnic slurs.",
    "Okay, Turd Ferguson.",
    "I hate my job.",
    "That is incorrect.",
    "Let's just get this over with.",
    "Do you have an answer?",
    "I don't believe this. Where did you get that magic marker? We frisked you in on the way in here.",
    "What a ride it has been, but boy, oh boy, these Slack users did not know the right answers to any of the questions.",
    "Back off. I don't have to take that from you.",
    "That is _awful_.",
    "Okay, for the sake of tradition, let's take a look at the answers.",
    "Beautiful. Just beautiful.",
    "Good for you. Well, as always, three perfectly good charities have been deprived of money, here on Slack Jeopardy. I'm #{ENV["BOT_USERNAME"]}, and all of you should be ashamed of yourselves! Good night!",
    "And welcome back to Slack Jeopardy. Because of what just happened before during the commercial, I'd like to apologize to all blind people and children.",
    "Thank you, thank you. Moving on.",
    "I really thought that was going to work.",
    "Wonderful. Let's take a look at the categories. They are: `Potent Potables`, `Point to your own head`, `Letters or Numbers`, `Will this hurt if you put it in your mouth`, `An album cover`, `Make any noise`, and finally, `Famous Muppet Frogs`. I should add that the answer to every question in that category is `Kermit`.",
    "For the last time, that is not a category.",
    "Unbelievable.",
    "Great. Let's take a look at the final board. And the categories are: `Potent Potables`, `Sharp Things`, `Movies That Start with the Word Jaws`, `A Petit Déjeuner` - that category is about French phrases, so let's just skip it.",
    "Enough. Let's just get this over with. Here are the categories, they are: `Potent Potables`, `Countries Between Mexico and Canada`, `Members of Simon and Garfunkel`, `I Have a Chardonnay` - you choose this category, you automatically get the points and I get to have a glass of wine - `Things You Do With a Pencil Sharpener`, `Tie Your Shoe`, and finally, `Toast`.",
    "Better luck to all of you, in the next round. It's time for Slack Jeopardy, let's take a look at the board. And the categories are: `Potent Potables`, `Literature` - which is just a big word for books - `Therapists`, `Current U.S. Presidents`, `Show and Tell`, `Household Objects`, and finally, `One-Letter Words`.",
    "Uh, I see. Get back to your podium.",
    "You look pretty sure of yourself. Think you've got the right answer?",
    "Welcome back to Slack Jeopardy. We've got a real barnburner on our hands here.",
    "And welcome back to Slack Jeopardy. I'd like to once again remind our contestants that there are proper bathroom facilities located _in_ the studio.",
    "Welcome back to Slack Jeopardy. Once again, I'm going to recommend that our viewers watch something else.",
    "Great. Better luck to all of you in the next round. It's time for Slack Jeopardy. Let's take a look at the board. And the categories are: `Potent Potables`, `The Vowels`, `Presidents Who Are On the One Dollar Bill`, `Famous Titles`, `Ponies`, `The Number 10`, and finally: `Foods That End In \"Amburger\"`.",
    "Let's take a look at the board. The categories are: `Potent Potables`, `The Pen is Mightier` - that category is all about quotes from famous authors, so you'll all probably be more comfortable with our next category - `Shiny Objects`, continuing with `Opposites`, `Things you Shouldn't Put in Your Mouth`, `What Time is It?`; and, finally, `Months That Start With Feb`."
  ]
    responses.sample
end

def get_help
  reply = <<help
Type `#{ENV["BOT_USERNAME"]} jeopardy me` to start a new round of Slack Jeopardy. I will pick the category and price. Anyone in the channel can respond.
Type `#{ENV["BOT_USERNAME"]} [what|where|who] [is|are] [answer]?` to respond to the active round. Remember, responses must be in the form of a question, e.g. `#{ENV["BOT_USERNAME"]} what is dirt?`.
Type `#{ENV["BOT_USERNAME"]} what is my score` to see your current score.
help
  json_response_for_slack(reply)
end

def json_response_for_slack(reply)
  response = { text: reply, link_names: 1 }
  response[:username] = ENV["BOT_USERNAME"] unless ENV["BOT_USERNAME"].nil?
  response[:icon_emoji] = ENV["BOT_ICON"] unless ENV["BOT_ICON"].nil?
  response.to_json
end
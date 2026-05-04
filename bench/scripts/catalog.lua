local counter = 0

function setup(thread)
  thread:set("offset", counter * 7919)
  counter = counter + 1
end

function init()
  n = offset or 0
  query = wrk.path:match("%?.*") or ""
end

function request()
  n = n + 1
  return wrk.format("GET", "/static/item/" .. (n % 1000) .. query)
end

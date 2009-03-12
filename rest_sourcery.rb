require 'httparty'
require 'activesupport'

%w{resource resource_collection_proxy}.each do |lib|
  require File.dirname(__FILE__) + "/lib/#{lib}"
end
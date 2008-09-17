module Injected
  require 'net/http'
  require 'uri'
  require 'hpricot'
  require 'openssl'

  class Service
    attr_accessor :developer_key, :secret, :namespace, :user_token, :server


    def initialize(user_token = nil)
      self.user_token = user_token
      options = YAML.load_file("#{RAILS_ROOT}/config/wetpaint.yml")[RAILS_ENV]
      options.each { |key,value| self.send("#{key}=", value) }
    end

    def server_url
      "http://#{self.server}"
    end

    protected
    def execute_call(params)
      method = params.delete(:method)
      path = params.delete(:path)

      params.merge!({ :key => self.developer_key,
                      :ns => self.namespace })

      url = "#{server_url}#{path}"
      RAILS_DEFAULT_LOGGER.debug "Injected: calling #{method.to_s.upcase} #{url}?#{params.to_query}"
      if method == :post
        result = self.post(url, params)
      else
        result = self.get(url, params)
      end

      result_body = (method == :post) ? result.body : result

      #RAILS_DEFAULT_LOGGER.debug "Result: #{result_body}"

      doc = Hpricot.parse(result_body)
      #check for xml response errors
      failure = doc.search("response/failure")
      raise InjectedException.new(failure.search('cause').inner_html,
                                  (failure.search("messages/message").collect &:inner_html)) unless failure.blank?
      # check for html response errors
      failure = doc.search("/p")
      raise InjectedException.new(failure.inner_html,
                                  (doc.search("li").collect &:inner_html)) unless failure.blank?


      if block_given?
        yield result
      else
        result_body
      end
    end

    def get(url, params)
      Net::HTTP.get(URI.parse("#{url}?#{params.to_query}"))
    end

    def post(url, params)
      Net::HTTP.post_form(URI.parse(url), params)
    end
  end

  class UserService < Service
    BASE_PATH = '/UserService/'

    MODERATOR_ROLE = 'moderator'
    REGISTERED_ROLE = 'registered'
    BANNED_ROLE = 'banned'

    def login(userId, email, role = 'registered', emailOptIn = false)
      timestamp = Time.now.to_i
      params =
        { 'user.userId' => userId,
          'user.email' => email,
          'user.role' => role,
          'user.emailOptIn' => emailOptIn,
          'cred.ts' => timestamp,
          'cred.sig' => OpenSSL::HMAC.hexdigest(OpenSSL::Digest::Digest.new('SHA1'), self.secret, "#{self.developer_key}#{userId}#{timestamp}"),
          :output => :api,
          :method => :post,
          :path => BASE_PATH + 'login.do' }

      execute_call(params) do |result|
        doc = Hpricot.parse(result.body)
        doc.search("response/ticket").innerHTML
      end
    end

    def logout(token)
      params =
        { :ticket => token,
          :output => :api,
          :method => :post,
          :path => BASE_PATH + 'logout.do' }
      begin
        execute_call(params)
      rescue InjectedException => ex
        #ignore errors on logout
      end
    end
  end

  class CellService < Service
    BASE_PATH = '/CellService/'

    def createCell(displayName, url, parentCellId = nil, cellId = nil)
      params = {
        'cell.displayName' => displayName,
        'cell.url' => url,
        :output => :api,
        :ticket => self.user_token,
        :method => :post,
        :path => BASE_PATH + 'createCell.do'
      }
      params['cell.parentCellId'] = parentCellId unless parentCellId.nil?
      params['cell.cellId'] = cellId unless cellId.nil?

      execute_call(params) do |result|
        doc = Hpricot.parse(result.body)
        doc.search("response/cell/cellId").innerHTML
      end
    end

    def getCellWithChildren(cellId)
      params = {
        'cell.cellId' => cellId,
        :method => :get,
        :path => BASE_PATH + 'getCellWithChildren.do'
      }

      execute_call(params)
    end

    def getCell(cellId)
      params = {
        'cell.cellId' => cellId,
        :method => :get,
        :path => BASE_PATH + 'getCell.do',
        :output => :api
      }

      execute_call(params)
    end

    def getCellContent(cellId)
      params = {
        'cell.cellId' => cellId,
        :method => :get,
        :path => BASE_PATH + 'getCellContent.do'
      }

      execute_call(params)
    end


  end

  class InjectedException < Exception
    attr_accessor :cause, :messages

    def initialize(cause, messages)
      self.cause = cause
      self.messages = messages
    end

    def message
      "Error occurred in WP Injected call - cause: #{self.cause}, messages: #{self.messages.join(', ')}"
    end
  end
end

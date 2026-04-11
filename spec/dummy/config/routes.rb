# frozen_string_literal: true

Rails.application.routes.draw do
  mount MysqlGenius::Engine => "/mysql_genius"
end

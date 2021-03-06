--- Trains the neural network.
-- @module train

require 'optim'
local arguments = require 'Settings.arguments'
local game_settings = require 'Settings.game_settings'
require 'Nn.masked_huber_loss'

local M = {}

--- Saves a neural net model to disk.
--
-- The model is saved to `arguments.model_path` and labelled with the epoch
-- number.
-- @param model the neural net to save
-- @param epoch the current epoch number
-- @param valid_loss the validation loss of the current network
-- @param learning_rate learning rate
-- @local
function M:_save_model(model, epoch, valid_loss, learning_rate)

  local model_information = {}
  model_information.epoch = epoch
  model_information.valid_loss = valid_loss
  model_information.learning_rate = learning_rate
  model_information.gpu = arguments.gpu

  local path = arguments.model_path
  if game_settings.nl then
    path = path .. "NoLimit/"
  else
    path = path .. "Limit/"
  end
  local net_type_str = arguments.gpu and '_gpu' or '_cpu'
  local model_file_name = path .. '/epoch_' .. epoch .. net_type_str .. '.model'
  local information_file_name = path .. '/epoch_' .. epoch .. net_type_str .. '.info'
  torch.save(model_file_name, model)
  torch.save(information_file_name, model_information)
end

--- Function passed to torch's [optim package](https://github.com/torch/optim).
-- @param params_new the neural network params
-- @param inputs the neural network inputs
-- @param targets the neural network targets
-- @param mask the mask vectors used for the loss function
-- @return the masked Huber loss on `inputs` and `targets`
-- @return the gradient of the loss function
-- @see masked_huber_loss
-- @local
local function feval(params_new, inputs, targets, mask)
  -- set x to x_new, if different
  -- (in this simple implementation, x_new will typically always point to x,
  -- so the copy is really useless)
  if M.params ~= params_new then
    M.params:copy(params_new)
  end

  M.grads:zero()
  local outputs = M.network:forward(inputs)
  local loss = M.criterion:forward(outputs, targets, mask)

  -- backward
  local dloss_doutput = M.criterion:backward(outputs, targets)
  M.network:backward(inputs, dloss_doutput)

  return loss, M.grads
end

--- Trains the neural network.
-- @param network the neural network (see @{net_builder})
-- @param data_stream a @{data_stream|DataStream} object which provides the
-- training data
-- @param epoch_count the number of epochs (passes of the training data) to train for
function M:train(network, data_stream, epoch_count)

  M.network = network
  M.data_stream = data_stream

  M.params, M.grads = network:getParameters()
  M.criterion = MaskedHuberLoss()

  if(arguments.gpu) then
    M.criterion = M.criterion:cuda()
  end

  M.min_validation_loss = 1.0
  M.epoch_num_min_validation_loss = 0
  
  local state = {learningRate = arguments.learning_rate}
  local lossSum = 0
  local optim_func = optim.adam

  -- optimization loop
  local timer = torch.Timer()
  for epoch = 1, epoch_count do
    timer:reset()
    data_stream:start_epoch(epoch)
    lossSum = 0
    local loss_min = 10000000.0
    local loss_max = 0

    if epoch == arguments.decrease_learning_at_epoch then
      state.learningRate = state.learningRate / 10
    end
    
    M.network:evaluate(false)
    for i = 1, data_stream:get_train_batch_count() do
      local inputs, targets, mask = data_stream:get_train_batch(i)
      assert(mask)
      local _, loss = optim_func(function (x) return feval(x, inputs, targets, mask) end, M.params, state)
      lossSum = lossSum + loss[1]
      loss_min = math.min(loss_min, loss[1])
      loss_max = math.max(loss_max, loss[1])
    end

    print(string.format('Training loss  : %f  min: %f  max: %f  learningRate: %f', lossSum / data_stream.train_batch_count, loss_min, loss_max, state.learningRate))

    M.network:evaluate(true)
    --check validation loss
    local valid_loss_sum = 0
    local valid_loss_min = 10000000.0
    local valid_loss_max = 0
  
    for i = 1, data_stream:get_valid_batch_count() do

      local inputs, targets, mask = data_stream:get_valid_batch(i)
      assert(mask)
      local outputs = M.network:forward(inputs)
      local loss = M.criterion:forward(outputs, targets, mask)
      valid_loss_sum = valid_loss_sum + loss
      valid_loss_min = math.min(valid_loss_min, loss)
      valid_loss_max = math.max(valid_loss_max, loss)
    end

    local valid_loss = valid_loss_sum / data_stream.valid_batch_count

    local progress = math.floor((M.min_validation_loss / valid_loss - 1) * 100 * 1000) / 1000

    if M.min_validation_loss > valid_loss then
      M.min_validation_loss = valid_loss
      M.epoch_num_min_validation_loss = epoch
    end

    print(string.format('Validation loss: %f  min: %f  max: %f', valid_loss, valid_loss_min, valid_loss_max))
    print(string.format('Validation progress    : %f    Last minimum found: %d epoch ago', progress, epoch - M.epoch_num_min_validation_loss))
    print(string.format('Current best validation: %f    Found at epoch: %d', M.min_validation_loss, M.epoch_num_min_validation_loss))
    next_time = os.date('*t', os.time() + math.floor(timer:time().real))
    print(string.format('Epoch took (s): %f  Timestamp: %s +2h   next time: %02d:%02d', timer:time().real, os.date("%H:%M"), next_time.hour, next_time.min))

    --saving the model
    print(string.format('Epoch / Total: %d / %d', epoch, epoch_count))
    if (epoch % arguments.save_epoch == 0) then
      self:_save_model(network, epoch, valid_loss, state.learningRate)
    end
  end
  --end of train loop

end

return M

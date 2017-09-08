function  [net1,net2,gen_mats,syn_mats,z] = process_epoch_dual(opts, epoch, net1, net2, config)

%% GPU (en) %%
if config.use_gpu
    net1 = vl_simplenn_move(net1, 'gpu') ;
    net2 = vl_simplenn_move(net2, 'gpu') ;
end

fprintf('Training: epoch %02d', epoch) ;
fprintf('\n');

% randomize order of training images
imdb = config.imdb;
train_order = randperm(size(imdb,4));
batchNum = 0;
epoch_time = tic;

for t = 1:config.batchSize:size(imdb,4)
    batchNum = batchNum+1;
    fprintf('Epoch %d of %d, Batch %d of %d \n', epoch,config.nIteration,batchNum, ceil(size(imdb,4)/config.batchSize));
    batchTime = tic;

    batchStart = t;
    batchEnd = min(t+config.batchSize-1, size(imdb,4)) ;
    batch = train_order(batchStart : batchEnd) ;
    im = imdb(:,:,:,batch);   
    
    %% Step 1: Inference Network 2 -- generate Z
    z = randn([config.z_sz, config.num_syn], 'single');

    %% GPU (en) %%
    if config.use_gpu
        z = gpuArray(z);
        syn_mat = vl_gan(net2, z, [], [],...
                'accumulate', 0, ...
                'disableDropout', 0, ...
                'conserveMemory', opts.conserveMemory, ...
                'backPropDepth', opts.backPropDepth, ...
                'sync', opts.sync, ...
                'cudnn', opts.cudnn) ;
    else
        syn_mat = vl_gan_cpu(net2, z, [], [],...
                'accumulate', 0, ...
                'disableDropout', 0, ...
                'conserveMemory', opts.conserveMemory, ...
                'backPropDepth', opts.backPropDepth, ...
                'sync', opts.sync, ...
                'cudnn', opts.cudnn) ;
    end


    syn_mats = floor(128*(syn_mat(end).x+1))-config.mean_im;
    

    %% GPU (en) %%
    if config.use_gpu
        gen_mats = gather(syn_mats);
    else
        gen_mats = syn_mats;
    end
    
    %% speedup (en) %%
    if config.use_gpu
        if mod(epoch,10) == 0 || epoch == config.nIteration
            gen_mats = gather(syn_mats);
            for i = 1:config.num_syn
                imwrite((gen_mats(:,:,:,i)+config.mean_im)/256,[config.gen_im_folder,'gen_im',num2str(i),'.png']);
            end
        end
    else
        for i = 1:config.num_syn
            imwrite((gen_mats(:,:,:,i)+config.mean_im)/256,[config.gen_im_folder,'gen_im',num2str(i),'.png']);
        end
    end

    %% Step 2 update generator mats by descriptor net
    % synthesize image according to current weights 
%     for syn_ind = 1:config.num_syn
%         %new_im = single(find_gen_min(net1,net2,config,z(:,:,:,syn_ind)));
%         %syn_mats(:,:,:,syn_ind) = new_im-config.mean_im;
% 
%         %% change GPU (en) %%
%         if config.use_gpu
%             syn_mats(:,:,:,syn_ind) = gather(langevin_dynamics_gpu(config,net1,syn_mats(:,:,:,syn_ind)));
%         else
%             syn_mats(:,:,:,syn_ind) = langevin_dynamics(config,net1,syn_mats(:,:,:,syn_ind));
%         end
%         
%         %syn_mats(:,:,:,syn_ind) = find_local_min(net1,config,syn_mats(:,:,:,syn_ind));
%     end
    
    syn_mats = langevin_dynamics_gpu(config, net1, syn_mats);
    
    z = langevin_dynamics_gen(config, net2, z, syn_mats);

    %% Step 3 learning net1

    %% GPU (en) %%
    if config.use_gpu
        dydz1 = gpuArray(zeros(config.dydz_sz1, 'single'));
        im = gpuArray(im);
    else
        dydz1 = zeros(config.dydz_sz1, 'single');
    end

    dydz1(net1.filterSelected) = net1.selectedLambdas;
    dydz1 = repmat(dydz1,1,1,1,size(im,4));
    res1 = [];
    res1 = vl_simplenn(net1, im, dydz1, res1, ...
        'accumulate', 0, ...
        'disableDropout', 0, ...
        'conserveMemory', opts.conserveMemory, ...
        'backPropDepth', opts.backPropDepth, ...
        'sync', opts.sync, ...
        'cudnn', opts.cudnn);

    dydz_syn = zeros(config.dydz_sz1, 'single');
    dydz_syn(net1.filterSelected) = net1.selectedLambdas;
    dydz_syn = gpuArray(repmat(dydz_syn,1,1,1,config.num_syn));
    res_syn = [];

    res_syn = vl_simplenn(net1, syn_mats, dydz_syn, res_syn, ...
        'accumulate', 0, ...
        'disableDropout', 0, ...
        'conserveMemory', opts.conserveMemory, ...
        'backPropDepth', opts.backPropDepth, ...
        'sync', opts.sync, ...
        'cudnn', opts.cudnn);

    % gather and accumulate gradients across labs
    [net1, ~] = accumulate_gradients1(opts, config.Gamma(epoch), size(im,4), net1, res1, res_syn, config);

    clear res;
    clear res_syn;

    %% speedup (en) %%
    if config.use_gpu
        if mod(epoch,10) == 0 || epoch == config.nIteration
            gen_mats = gather(syn_mats);
            for k = 1:config.num_syn
                imwrite((gen_mats(:,:,:,k)+config.mean_im)/256,[config.syn_im_folder,'syn_im',num2str(k),'.png']);
            end
        end
    else
        for k = 1:config.num_syn
            imwrite((syn_mats(:,:,:,k)+config.mean_im)/256,[config.syn_im_folder,'syn_im',num2str(k),'.png']);
        end
    end

    syn_mats = max(min(syn_mats+config.mean_im,255.99),0.01)/128 - 1;

    %% Step 3: Learning net2
    res2 = [];
    
    %% GPU (en) %%
    if config.use_gpu
            res2 = vl_gan(net2, z, syn_mats, res2, ...
                'accumulate', 0, ...
                'disableDropout', 0, ...
                'conserveMemory', opts.conserveMemory, ...
                'backPropDepth', opts.backPropDepth, ...
                'sync', opts.sync, ...
                'cudnn', opts.cudnn) ;
    else
        res2 = vl_gan_cpu(net2, z, syn_mats, res2, ...
            'accumulate', 0, ...
            'disableDropout', 0, ...
            'conserveMemory', opts.conserveMemory, ...
            'backPropDepth', opts.backPropDepth, ...
            'sync', opts.sync, ...
            'cudnn', opts.cudnn) ;
    end


    net2 = accumulate_gradients2(opts, config.Gamma2(epoch), size(im,4), net2, res2, config);     

    real_ref = std(z(:));
    config.real_ref = real_ref;  
    fprintf('max inferred z is %.2f, min inferred z is %.2f, and std is %.2f\n', max(z(:)), min(z(:)), config.real_ref)  

    batchTime = toc(batchTime);
    speed = 1/batchTime ;
    disp(batchTime);
    fprintf(' %Time: .2f s (%.1f data/s)', batchTime, speed) ;
    fprintf('\n') ;
end

%% GPU (en) %%
if config.use_gpu
    net1 = vl_simplenn_move(net1, 'cpu') ;
    net2 = vl_simplenn_move(net2, 'cpu') ;
end

%% speedup (en) %%
if config.use_gpu
    if mod(epoch,10) == 0 || epoch == config.nIteration
        save([config.trained_folder,'des_net.mat'],'net1');
        save([config.trained_folder,'gen_net.mat'],'net2');
    end
else
    save([config.trained_folder,'des_net.mat'],'net1');
    save([config.trained_folder,'gen_net.mat'],'net2');
end

% print learning statistics
epoch_time = toc(epoch_time) ;
speed = config.num_syn/epoch_time;

fprintf(' %.2f s (%.1f data/s)', epoch_time, speed) ;
fprintf('\n') ;
end

% -------------------------------------------------------------------------
function [net,res] = accumulate_gradients1(opts, lr, batchSize,net, res, res_syn, config)
% -------------------------------------------------------------------------
layer_sets = config.layer_sets1;

for l = layer_sets
    for j=1:numel(res(l).dzdw)
        thisDecay = opts.weightDecay * net.layers{l}.weightDecay(j) ;
        thisLR = lr * net.layers{l}.learningRate(j) ;

        if isfield(net.layers{l}, 'weights')
            
            gradient_dzdw = ((1 / batchSize) * res(l).dzdw{j} -  ...
                        (1 / config.num_syn) * res_syn(l).dzdw{j}) / net.numFilters(l);
                    
            if max(abs(gradient_dzdw(:))) > 20 %10
                gradient_dzdw = gradient_dzdw / max(abs(gradient_dzdw(:))) * 20;
            end
            
            net.layers{l}.momentum{j} = ...
                + opts.momentum * net.layers{l}.momentum{j} ...
                - thisDecay * net.layers{l}.weights{j} ...
                + gradient_dzdw;
            
            net.layers{l}.weights{j} = net.layers{l}.weights{j} + thisLR *net.layers{l}.momentum{j};
            
            if j == 1
                res_l = min(l+2, length(res));
                fprintf('\n layer %s:max response is %f, min response is %f.\n', net.layers{l}.name, max(res(res_l).x(:)), min(res(res_l).x(:)));
                fprintf('max gradient is %f, min gradient is %f, learning rate is %f\n', max(gradient_dzdw(:)), min(gradient_dzdw(:)), thisLR);
            end
        end
    end
end
end

% -------------------------------------------------------------------------
function [net, res] = accumulate_gradients2(opts, lr, batchSize, net, res, config)
% -------------------------------------------------------------------------
layer_sets = config.layer_sets2;

for l = layer_sets
    for j=1:numel(res(l).dzdw)
        thisDecay = opts.weightDecay * net.layers{l}.weightDecay(j) ;
        thisLR = lr * net.layers{l}.learningRate(j) ;
        
        if isfield(net.layers{l}, 'weights')
            % gradient descent
            % gradient_dzdw = (1 / config.s / config.s) * res(l).dzdw{j};
            gradient_dzdw = (1 / batchSize) * (1 / config.s / config.s) * res(l).dzdw{j};
            
            max_val = max(abs(gradient_dzdw(:)));
            
            if max_val > config.cap2
                gradient_dzdw = gradient_dzdw / max_val * config.cap2;
            end
  
            net.layers{l}.momentum{j} = ...
                + opts.momentum * net.layers{l}.momentum{j} ...
                - thisDecay * net.layers{l}.weights{j} ...
                + gradient_dzdw;
            
            net.layers{l}.weights{j} = net.layers{l}.weights{j} + thisLR * net.layers{l}.momentum{j};
            
            if j == 1
                res_l = min(l+2, length(res));
                fprintf('Net2: layer %s:max response is %f, min response is %f.\n', net.layers{l}.name, max(res(res_l).x(:)), min(res(res_l).x(:)));
                fprintf('max gradient is %f, min gradient is %f, learning rate is %f\n', max(gradient_dzdw(:)), min(gradient_dzdw(:)), thisLR);
            end
        end
    end
end
end


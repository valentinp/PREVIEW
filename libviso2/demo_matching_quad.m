% demonstrates sparse scene flow (quad matching = 2 consecutive stereo pairs)
disp('===========================');
clear all; dbstop error; close all;

% read images from file
I1p = imread('../img/I1p.png');
I2p = imread('../img/I2p.png');
I1c = imread('../img/I1c.png');
I2c = imread('../img/I2c.png');

% matching parameters
param.nms_n                  = 2;   % non-max-suppression: min. distance between maxima (in pixels)
param.nms_tau                = 50;  % non-max-suppression: interest point peakiness threshold
param.match_binsize          = 50;  % matching bin width/height (affects efficiency only)
param.match_radius           = 200; % matching radius (du/dv in pixels)
param.match_disp_tolerance   = 1;   % du tolerance for stereo matches (in pixels)
param.outlier_disp_tolerance = 5;   % outlier removal: disparity tolerance (in pixels)
param.outlier_flow_tolerance = 5;   % outlier removal: flow tolerance (in pixels)
param.multi_stage            = 1;   % 0=disabled,1=multistage matching (denser and faster)
param.half_resolution        = 0;   % 0=disabled,1=match at half resolution, refine at full resolution
param.refinement             = 0;   % refinement (0=none,1=pixel,2=subpixel)

% init matcher
matcherMex('init',param);

matcherMex('bucketing',10,50,50);
% push back images
matcherMex('push',I1p,I2p); tic;
matcherMex('push',I1c,I2c); 
disp(['Feature detection: ' num2str(toc) ' seconds']);

% match images
tic; matcherMex('match',2);
p_matched = matcherMex('get_matches',2);
disp(['Feature matching:  ' num2str(toc) ' seconds']);

% close matcher
matcherMex('close');

% show matching results
disp(['Number of matched points: ' num2str(length(p_matched))]);
disp('Plotting ...');
figure('Position',[1200 30 size(I1c,2) size(I1c,1)]); axes('Position',[0 0 1 1]);
plotMatch(I1c,p_matched,2);

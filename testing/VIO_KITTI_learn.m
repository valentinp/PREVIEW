disp('===========================');
addpath('libviso2');
addpath('datasets/extraction/utils');
addpath('datasets/extraction/utils/devkit');
addpath('utils');
addpath('learning');
dataBaseDir = '/Users/valentinp/Desktop/KITTI/2011_09_26/2011_09_26_drive_0005_sync';
dataCalibDir = '/Users/valentinp/Desktop/KITTI/2011_09_26';
%% Get ground truth and import data
frameRange = 1:150;
%Image data
leftImageData = loadImageData([dataBaseDir '/image_00'], frameRange);
rightImageData = loadImageData([dataBaseDir '/image_01'], frameRange);
%IMU data
[imuData, imuFrames] = loadImuData(dataBaseDir, leftImageData.timestamps);
%Ground Truth
T_wIMU_GT = getGroundTruth(dataBaseDir, imuFrames);
skipFrames = 1;

%% Load calibration and parameters
[T_camvelo_struct, P_rect_cam1] = loadCalibration(dataCalibDir);
T_camvelo = T_camvelo_struct{1}; 
T_veloimu = loadCalibrationRigid(fullfile(dataCalibDir,'calib_imu_to_velo.txt'));
T_camimu = T_camvelo*T_veloimu;

%Add camera ground truth
T_wCam_GT = T_wIMU_GT;

for i = 1:size(T_wIMU_GT, 3)
    T_wCam_GT(:,:,i) = T_wIMU_GT(:,:,i)*inv(T_camimu);
end

K= P_rect_cam1(:,1:3);
b_pix = P_rect_cam1(1,4);

cu = K(1,3);
cv = K(2,3);
fu = K(1,1);
fv = K(2,2);
b = -b_pix/fu; %The KITTI calibration supplies the baseline in units of pixels

calibParams.c_u = cu;
calibParams.c_v = cv;
calibParams.f_u = fu;
calibParams.f_v = fv;
calibParams.b = b;

%LIBVISO2 matching
param.f     = fu;
param.cu    = cu;
param.cv    = cv;
param.base  = b;
param.nms_n                  = 5;   % non-max-suppression: min. distance between maxima (in pixels)
param.nms_tau                = 50;  % non-max-suppression: interest point peakiness threshold
param.match_binsize          = 50;  % matching bin width/height (affects efficiency only)
param.match_radius           = 200; % matching radius (du/dv in pixels)
param.match_disp_tolerance   = 1;   % du tolerance for stereo matches (in pixels)
param.outlier_disp_tolerance = 5;   % outlier removal: disparity tolerance (in pixels)
param.outlier_flow_tolerance = 5;   % outlier removal: flow tolerance (in pixels)
param.multi_stage            = 1;   % 0=disabled,1=multistage matching (denser and faster)
param.half_resolution        = 1;   % 0=disabled,1=match at half resolution, refine at full resolution
param.refinement             = 0;   % refinement (0=none,1=pixel,2=subpixel)

%% Setup
addpath('settings');
addpath('utils');

R = diag(16*ones(4,1));
optParams.RANSACCostThresh = 0.2;
optParams.maxGNIter = 10;
optParams.lineLambda = 0.5;
optParams.LMlambda = 1e-5;

%% Main loop

% create figure
% figure('Color',[1 1 1]);
% ha1 = axes('Position',[0.05,0.7,0.9,0.25]);
% %axis off;
% ha2 = axes('Position',[0.05,0.05,0.9,0.6]);
% axis equal, grid on, hold on;

repeatIter =  10;
learnedPredSpace.predVectors = [];
learnedPredSpace.weights = [];
p_wcam_hist = NaN(3,length(frameRange), repeatIter);

for repeat_i = 1:repeatIter
    
usedPredVectors = [];
rng('shuffle');
% init matcher
matcherMex('init',param);
% push back first images
I1prev = uint8(leftImageData.rectImages(:,:,1));
I2prev = uint8(rightImageData.rectImages(:,:,1));
matcherMex('push',I1prev,I2prev); 

numFrames = size(leftImageData.rectImages, 3);
k =1;
T_wcam = eye(4);
T_wcam_hist = T_wcam;
p_wcam_hist(:, 1, repeat_i) = zeros(3,1);

% history variables
firstState.C_vi = eye(3);
firstState.r_vi_i = zeros(3,1);
firstState.k = 1;
oldState = firstState;

for frame=2:skipFrames:numFrames
  
    %IMU Data
    imuMeasurement.omega = imuData.measOmega(:, frame-1);
    imuMeasurement.v = imuData.measVel(:, frame-1);
    deltaT = imuData.timestamps(frame) - imuData.timestamps(frame-1);
    
    %Get an estimate through IMU propagation
    newState = propagateState(oldState, imuMeasurement, deltaT);
    T_21_imu = getTransformation(oldState, newState);
    T_21_cam = T_camimu*T_21_imu*inv(T_camimu);
    oldState = newState;

    % read current images
    I1 = uint8(leftImageData.rectImages(:,:,frame));
    I2 = uint8(rightImageData.rectImages(:,:,frame));
    
 
      %Plot image
%       axes(ha1); cla;
%       imagesc(I1);
%       axis off;

    matcherMex('push',I1,I2); 
    % match images
    matcherMex('match',2);
    p_matched = matcherMex('get_matches',2);
    % show matching results
    disp(['Number of matched points: ' num2str(length(p_matched))]);

    %Triangulate points and prune any at Infinity
    [p_f1_1, p_f2_2] = triangulateAllPointsDirect(p_matched, calibParams);
    pruneId = isinf(p_f1_1(1,:)) | isinf(p_f1_1(2,:)) | isinf(p_f1_1(3,:)) | isinf(p_f2_2(1,:)) | isinf(p_f2_2(2,:)) | isinf(p_f2_2(3,:));
    p_f1_1 = p_f1_1(:, ~pruneId);
    p_f2_2 = p_f2_2(:, ~pruneId);
    
    %Select a random subset of 100
    selectIdx = randperm(size(p_f1_1,2), 5);
    p_f1_1 = p_f1_1(:, selectIdx);
    p_f2_2 = p_f2_2(:, selectIdx);
    p_matched = p_matched(:, selectIdx);
    inliers = 1:size(p_f1_1,2);

    %Find inliers based on rotation matrix from IMU
     %[p_f1_1, p_f2_2, T_21_est, inliers] = findInliersRot(p_f1_1, p_f2_2, T_21_cam(1:3,1:3), optParams);
    [predVectors] = computePredVectors( p_matched(1:2,inliers), I1, I1prev, [imuData.measAccel(:, frame-1); imuData.measOmega(:, frame-1)]);
    usedPredVectors(:,end+1:end+size(predVectors, 2)) = predVectors;
    %fprintf('Tracking %d features.', size(p_f1_1,2));
    
    %Calculate initial guess using scalar weights, then use matrix weighted
    %non linear optimization

    R_1 = repmat(R, [1 1 size(p_f1_1, 2)]);
    R_2 = R_1;
    T_21_est = scalarWeightedPointCloudAlignment(p_f1_1, p_f2_2,T_21_cam(1:3,1:3));
    T_21_opt = matrixWeightedPointCloudAlignment(p_f1_1, p_f2_2, R_1, R_2, T_21_est, calibParams, optParams);


    T_wcam = T_wcam*inv(T_21_opt);
    T_wcam_hist(:,:,end+1) = T_wcam;
    
    p_wcam_hist(:, frame, repeat_i) = T_wcam(1:3,4);
    
    % update trajectory and plot
%     axes(ha2);
%     plot(T_wcam(1,4),T_wcam(3,4),'g*');
%     hold on;
%     grid on;
%    drawnow();
    I1prev = I1;
    I2prev = I2;
    k = k + 1;
    fprintf('k:%d, repeat_i: %d \n',k,repeat_i);
end

% close matcher
matcherMex('close');

p_vi_i = NaN(3, size(T_wCam_GT,3));
for j = frameRange
    T_wcam_gt =  inv(T_wCam_GT(:,:,1))*T_wCam_GT(:,:, j);
    p_vi_i(:,j) = T_wcam_gt(1:3,4);
end
translation = NaN(3, size(T_wcam_hist, 3));
for i = 1:size(T_wcam_hist, 3)
    T_wcam =  T_wcam_hist(:, :, i);
    translation(:,i) = T_wcam(1:3, 4);
end

%Plot error and variances
transErrVec = zeros(3, length(frameRange));
for i = frameRange
    transErrVec(:,i) = translation(:, i) - p_vi_i(:,i);
end
meanRMSE = mean(sqrt(sum(transErrVec.^2,1)/3))

%Update the prediction space learning
 learnedPredSpace.predVectors = [learnedPredSpace.predVectors usedPredVectors];
 learnedPredSpace.weights = [learnedPredSpace.weights meanRMSE*ones(1, size(usedPredVectors,2))];


end
learnedPredSpace

f = strsplit(dataBaseDir, '/');
f = strsplit(char(f(end)), '.');
fileName = ['learnedProbeModels/' char(f(1)) '_learnedPredSpaceIter' int2str(repeatIter) '.mat'];
save(fileName, 'learnedPredSpace');

%%
%% Plot trajectories
totalDist = 0;
p_wcam_w_gt = NaN(3, size(T_wCam_GT,3));
for j = frameRange
    if j > 1
        T_12 = inv(T_wCam_GT(:,:,j-1))*T_wCam_GT(:,:, j);
        totalDist = totalDist + norm(T_12(1:3,4));
    end
    T_wcam_gt =  inv(T_wCam_GT(:,:,1))*T_wCam_GT(:,:, j);
    p_wcam_w_gt(:,j) = T_wcam_gt(1:3,4);
end

figure
for p_i = 1:size(p_wcam_hist,3)
    plot(p_wcam_hist(1,:,p_i),p_wcam_hist(3,:,p_i), '-b', 'LineWidth', 1);
    hold on;
end
plot(p_wcam_w_gt(1,:),p_wcam_w_gt(3,:), '-r', 'LineWidth', 2);
f = strsplit(dataBaseDir, '/');
f = strsplit(char(f(end)), '.');
fileName = char(f(1));

title(sprintf('Training Runs \n %s', fileName), 'Interpreter', 'none')
xlabel('x [m]')
ylabel('z [m]')

%legend('Training Runs', 'Ground Truth')
grid on;
saveas(gcf,sprintf('plots/%s_training500.fig', fileName));
save(sprintf('plots/%s_paths500.mat', fileName), 'p_wcam_hist', 'p_wcam_w_gt');

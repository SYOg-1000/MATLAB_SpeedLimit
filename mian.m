% 核心架构:
%   1. 预处理: CLAHE增强 + HSV双区间颜色流形分割
%   2. 定位: 多准则连通域形态学筛选 + IoU-NMS 多目标解耦
%   3. 矫正: 边缘提取 + 仿射透视粗校正
%   4. 分割: 内区裁剪 + 连通域拓扑提取 (自带X轴升序排序)
%   5. 识别: 双线性归一化 (32x16) + 二维相关系数(corr2)联合决策
% =========================================================================

function mian()
    clear; clc; close all;
    
    % fprintf('====================================================\n');
    % fprintf('|| 交通限速标志识别系统 v2.0 \n');
    % fprintf('|| 电子科技大学《数学实验》课程配套实现 \n');
    % fprintf('====================================================\n\n');
    
    %% 0. 模板构建 (如果不存在则自动生成 0-9 的 32x16 标准模板)
    TEMPLATE_FILE = 'tsr_templates_v2.mat';
    if ~exist(TEMPLATE_FILE, 'file')
        fprintf('[INIT] 模板文件不存在, 正在生成标准数字模板...\n');
        build_templates(TEMPLATE_FILE);
    else
        fprintf('[INIT] 已加载模板文件: %s\n', TEMPLATE_FILE);
    end
    load(TEMPLATE_FILE, 'templates');   %load variable templates in TEMPLATE_FILE to workspace
    
    %% 1. 图像载入 (支持批量多选)
    [fileNames, filePath] = uigetfile(...
        {'*.png;*.jpg;*.jpeg;*.bmp', '图像文件(*.png, *.jpg, *.bmp)'}, ...
        '选择测试图片(支持Ctrl多选)', 'MultiSelect', 'on');
    
    if isequal(fileNames, 0)
        fprintf('[用户] 已取消, 程序退出。\n'); 
        return;
    end
    if ischar(fileNames)
        fileNames = {fileNames}; % 统一转换为 cell array
    end
    
    %% 2. 逐图处理主循环
    for fIdx = 1:length(fileNames)
        imgPath = fullfile(filePath, fileNames{fIdx});
        fprintf('\n[%d/%d] 处理图像: %-30s\n', fIdx, length(fileNames), fileNames{fIdx});
        
        origin_img = imread(imgPath);
        origin_img = ensure_rgb(origin_img); % 统一转为三通道 RGB，这是由于imread读取的图像不同输出位数就不同
        
        process_single_image(origin_img, fileNames{fIdx}, templates);
    end
    fprintf('\n[完成] 所有图像处理完毕。\n');
end

% =========================================================================
% 工具函数: 确保图像为 uint8 三通道 RGB
% =========================================================================
function img = ensure_rgb(img)  %强制3通道RGB
    if ~isa(img, 'uint8'), img = im2uint8(img); end %判断是否为uint8类型,并且转化
    if size(img, 3) == 1
        img = repmat(img, [1 1 3]);
    elseif size(img, 3) == 4
        img = img(:,:,1:3); % 剥离 Alpha 透明通道
    end
end

% =========================================================================
% 核心管线: 单张图像完整处理流程
% =========================================================================
function process_single_image(origin_img, img_name, templates)
    %输入的origin_img为3通道RGB图像，在主函数为origin_img
    %输入的templates为32x16的交通限速标志模板矩阵，在主函数为templates
    % Step 1: HSV 颜色流形分割 (引入 CLAHE 抗光照干扰)
    [mask_red, V_enhanced] = color_segment_red(origin_img);
    
    % Step 2: 多准则形态学定位与 IoU-NMS 多目标过滤
    [roi_cells, roi_bboxes, mask_final, sign_metas] = locate_signs_robust(origin_img, mask_red);
    
    % 可视化面板设置
    hFig = figure('Name', ['TSR | ' img_name], 'NumberTitle', 'off', ...
                  'Position', [50, 50, 1200, 800], 'Color', [0.9 0.9 0.9]);
    
    % ① 原始图像与 NMS 定位框
    subplot(2, 3, 1); imshow(origin_img); title('① 原始图像与 NMS 定位框'); hold on;
    colors_box = {'cyan', 'yellow', 'lime', 'magenta'};
    for k = 1:length(roi_bboxes)
        bb = roi_bboxes{k};
        clr = colors_box{mod(k-1,4)+1};
        rectangle('Position', bb, 'EdgeColor', clr, 'LineWidth', 2.5);
        text(bb(1), bb(2)-10, sprintf('#%d', k), 'Color', clr, 'FontSize', 12, 'FontWeight', 'bold');
    end
    hold off;
    
    % ② CLAHE 增强 V 通道
    subplot(2, 3, 2); imshow(V_enhanced); title('② CLAHE 增强 V 通道');
    
    % ③ 形态学纯化红色掩膜
    subplot(2, 3, 3); imshow(mask_final); title('③ 形态学纯化红色掩膜');
    
    if isempty(roi_cells)
        fprintf('  -> [定位] 未检测到符合条件的限速标志。\n');
        return;
    end
    
    % Step 3: 逐候选标志处理 (提取、分割、识别)
    all_results = {};
    for k = 1:length(roi_cells)
        roi_img = roi_cells{k};
        meta = sign_metas{k};
        
        % 3a. 仿射透视粗校正 (对抗形变)
        roi_corrected = perspective_correction(roi_img, meta);
        
        % 3b. 内部区域裁剪 (去除边缘红圈残余)
        roi_inner = extract_inner_region(roi_corrected); %其逻辑是缩进15%
        
        % 3c. 字符分割 (大津法二值化 + 取反 + 拓扑排序)
        [char_cells, bw_clean] = segment_chars(roi_inner);
        
        % 3d. 模板匹配联合决策
        if isempty(char_cells)
            speed_val = '??'; confidence = 0;
        else
            [speed_val, confidence] = recognize_digits(char_cells, templates);
        end
        all_results{k} = speed_val;
        
        fprintf('  -> 标志 #%d: 识别结果 = %s km/h (置信度: %.1f%%)\n', k, speed_val, confidence*100);
        
        % 只详细展示第一个检测到的标志的中间过程
        if k == 1 
            % ④ ROI 仿射校正
            subplot(2, 3, 4); imshow(roi_corrected); title('④ ROI 仿射校正');
            
            % ⑤ 内部二值化与去噪
            subplot(2, 3, 5); imshow(bw_clean); title('⑤ 内部二值化与去噪 (已取反)');
            
            % ⑥ 字符切片匹配 (在subplot(2,3,6)内手动布局子轴)
            subplot(2, 3, 6); title(sprintf('⑥ 字符切片匹配 [%s]', speed_val)); axis off;
            num_chars = length(char_cells);
            if num_chars > 0
                ax6_pos = get(gca, 'Position');
                cell_w = ax6_pos(3) / num_chars;
                for c = 1:num_chars
                    pos = [ax6_pos(1) + (c-1)*cell_w + cell_w*0.1, ...
                           ax6_pos(2) + ax6_pos(4)*0.15, ...
                           cell_w*0.7, ax6_pos(4)*0.7];
                    ax_c = axes('Position', pos);
                    imshow(char_cells{c});
                    title(sprintf('C%d', c), 'FontSize', 8);
                    axis off;
                end
            end
        end
    end
end

% =========================================================================
% 模块 A: 红色流形分割 (HSV + CLAHE)
% =========================================================================
function [mask_red, V_enhanced] = color_segment_red(rgb_img)    
%输入的rgb_img为3通道RGB图像，在主函数为origin_img
%输出的mask_red为3通道二值图像，用于定位红色限速标志
%输出的V_enhanced为3通道图像，用于可视化增强后的V通道
    hsv_img = rgb2hsv(double(rgb_img) / 255);   %RGB changed to HSV, 归一化到 [0, 1]
    H = hsv_img(:,:,1); S = hsv_img(:,:,2); V = hsv_img(:,:,3); % 提取 HSV 通道
    
    % CLAHE 增强: 极大改善暗光/过曝场景的对比度 (如 60-3.png)
    % --- 可调参数 ---
    CLAHE_NumTiles = [8 8];        % 区域划分数目: [n m]，值越小对比度越强
    CLAHE_ClipLimit = 0.02;        % 对比度增强限制: 值越小对比度越强

    V_enhanced = adapthisteq(V, 'NumTiles', CLAHE_NumTiles, 'ClipLimit', CLAHE_ClipLimit);  %将HSV的V通道增强对比度，划分8*8个区域，对比度阈值0.02
    
    % 红色双区间掩膜 (HSV 色相环 0 附近和 1 附近均为红色)
    mask_low  = (H <= 0.08) & (S > 0.35) & (V_enhanced > 0.15);
    mask_high = (H >= 0.92) & (S > 0.35) & (V_enhanced > 0.15);
    mask_union = mask_low | mask_high;
    
    % 形态学开运算消除孤立噪点
    mask_red = imopen(mask_union, strel('disk', 2));
end

% =========================================================================
% 模块 B: 多准则连通域筛选 + IoU-NMS 
% =========================================================================
function [roi_cells, roi_bboxes, mask_final, sign_metas] = locate_signs_robust(origin_img, mask_red)
    roi_cells = {}; roi_bboxes = {}; sign_metas = {};
    
    % 闭运算连接断裂弧段，填孔使得圆环变实心大饼
    mask_closed = imclose(mask_red, strel('disk', 8));
    mask_filled = imfill(mask_closed, 'holes');
    mask_final = mask_filled;
    
    stats = regionprops(mask_filled, 'Area', 'BoundingBox', 'Perimeter', 'Extent', 'MajorAxisLength', 'MinorAxisLength');
    if isempty(stats), return; end
    
    max_area = max([stats.Area]);
    candidate_idx = [];
    
    % 联合多准则筛选
    for i = 1:length(stats)
        A = stats(i).Area; P = stats(i).Perimeter; Ext = stats(i).Extent;
        if P < 1, continue; end
        circ = (4 * pi * A) / (P^2); % 圆形度
        AR = stats(i).MajorAxisLength / max(stats(i).MinorAxisLength, 1); % 长宽比
        
        % 面积够大 + 矩形度合理 + 圆形度/长宽比容忍透视变形
        if (A > 600) && (A > max_area * 0.10) && (Ext > 0.45) && (AR < 2.5) && (circ > 0.40)
            candidate_idx(end+1) = i;
        end
    end
    
    if isempty(candidate_idx), return; end
    cand_stats = stats(candidate_idx);
    
    % NMS (非极大抑制): 防止同一个标志牌被大框和小框重复截取
    bboxes_mat = vertcat(cand_stats.BoundingBox);
    areas_mat = [cand_stats.Area];
    keep_flags = nms_boxes(bboxes_mat, areas_mat, 0.40);
    final_idx = candidate_idx(keep_flags);
    
    % 截取 ROI
    [H_img, W_img, ~] = size(origin_img);
    PAD = 15; % 向外扩展安全边界
    for i = 1:length(final_idx)
        si = stats(final_idx(i)); bb = si.BoundingBox;
        x1 = max(floor(bb(1)) - PAD, 1);          y1 = max(floor(bb(2)) - PAD, 1);
        x2 = min(floor(bb(1) + bb(3)) + PAD, W_img); y2 = min(floor(bb(2) + bb(4)) + PAD, H_img);
        
        roi_cells{end+1} = origin_img(y1:y2, x1:x2, :);
        roi_bboxes{end+1} = [x1, y1, x2-x1, y2-y1];
        
        circ_k = (4*pi*si.Area) / max(si.Perimeter^2, 1);
        sign_metas{end+1} = struct('aspect_ratio', si.MajorAxisLength/max(si.MinorAxisLength,1), 'circularity', circ_k);
    end
end

% =========================================================================
% NMS 实现
% =========================================================================
function keep = nms_boxes(bboxes, areas, iou_thresh)
    n = size(bboxes, 1); keep = true(1, n);
    [~, order] = sort(areas, 'descend');
    for ii = 1:n
        if ~keep(order(ii)), continue; end
        for jj = ii+1:n
            if ~keep(order(jj)), continue; end
            bb1 = bboxes(order(ii),:); bb2 = bboxes(order(jj),:);
            ix1 = max(bb1(1), bb2(1)); iy1 = max(bb1(2), bb2(2));
            ix2 = min(bb1(1)+bb1(3), bb2(1)+bb2(3)); iy2 = min(bb1(2)+bb1(4), bb2(1)+bb2(4));
            inter = max(0, ix2-ix1) * max(0, iy2-iy1);
            union = bb1(3)*bb1(4) + bb2(3)*bb2(4) - inter;
            if (inter / union) > iou_thresh
                keep(order(jj)) = false;
            end
        end
    end
end

% =========================================================================
% 模块 C: 仿射透视粗校正
% =========================================================================
function roi_out = perspective_correction(roi_in, meta)
    % 当形变不明显时直接跳过，防止过拟合
    if meta.aspect_ratio < 1.15 || meta.circularity > 0.80
        roi_out = roi_in; return; 
    end
    try
        % 简化的基于长宽比的 Resize 拉伸校正 (代替复杂的 affine2d)
        [h, w, c] = size(roi_in);
        target_size = max(h, w);
        roi_out = imresize(roi_in, [target_size, target_size]);
    catch
        roi_out = roi_in;
    end
end

% =========================================================================
% 模块 D: 内部数字区提取 (向内缩进比例裁剪红圈)
% =========================================================================
function inner = extract_inner_region(roi_img)
    [H_r, W_r, ~] = size(roi_img);
    my = round(H_r * 0.15); % 上下各缩进 15%
    mx = round(W_r * 0.15); % 左右各缩进 15%
    inner = roi_img(my:(H_r-my), mx:(W_r-mx), :);
end

% =========================================================================
% 模块 E: 字符分割与归一化 (大津法二值化 + 取反 + 拓扑排序)
% =========================================================================
function [char_cells, bw_clean] = segment_chars(roi_img)
    char_cells = {};
    gray_img = rgb2gray(roi_img);
    
    % 大津法二值化，并进行至关重要的取反 (~) 使得黑字变白目标 (1)
    bw = ~imbinarize(gray_img, graythresh(gray_img));
    
    % 清除边界残留的红色外圈像素
    bw_clean = imclearborder(bw);
    bw_clean = bwareaopen(bw_clean, 30); % 移除小于 30 像素的噪点
    
    stats = regionprops(bw_clean, 'BoundingBox', 'Area');
    if isempty(stats), return; end
    
    % 根据面积和长宽比初筛字符连通域
    valid_bboxes = [];
    max_a = max([stats.Area]);
    for i = 1:length(stats)
        bb = stats(i).BoundingBox;
        if stats(i).Area > max_a * 0.15 && bb(4)/bb(3) > 1.1 % 字符通常是瘦高的
            valid_bboxes = [valid_bboxes; bb];
        end
    end
    
    if isempty(valid_bboxes), return; end
    
    % 核心: 按 X 坐标排序，确保 60 不会被识别为 06
    [~, sort_idx] = sort(valid_bboxes(:, 1));
    valid_bboxes = valid_bboxes(sort_idx, :);
    
    % 裁剪并归一化到 32x16
    for i = 1:size(valid_bboxes, 1)
        bb = valid_bboxes(i, :);
        % 略微向外扩展确保不切掉字符边缘
        x = max(floor(bb(1))-1, 1); y = max(floor(bb(2))-1, 1);
        w = min(ceil(bb(3))+2, size(bw_clean,2)-x); h = min(ceil(bb(4))+2, size(bw_clean,1)-y);
        
        char_img = bw_clean(y:y+h, x:x+w);
        char_cells{i} = imresize(char_img, [32, 16]);
    end
end

% =========================================================================
% 模块 F: 模板匹配核心 (corr2)
% =========================================================================
function [speed_val, confidence] = recognize_digits(char_cells, templates)
    speed_val = '';
    conf_list = [];
    
    for i = 1:length(char_cells)
        test_char = char_cells{i};
        max_corr = -1;
        best_digit = '?';
        
        for num = 0:9
            tpl = templates{num + 1};
            r = corr2(test_char, tpl);
            if r > max_corr
                max_corr = r;
                best_digit = num2str(num);
            end
        end
        speed_val = [speed_val, best_digit];
        conf_list(end+1) = max_corr;
    end
    confidence = mean(conf_list);
end

% =========================================================================
% 模块 G: 生成标准数字模板库 (0-9)
% =========================================================================
function build_templates(template_file)
    digits = {'0','1','2','3','4','5','6','7','8','9'};
    templates = {};
    for i = 1:length(digits)
        fig = figure('Units', 'pixels', 'Position', [0 0 160 320], 'Color', 'white', 'Visible', 'off');
        text(80, 200, digits{i}, 'FontSize', 200, 'FontName', 'Times New Roman', ...
             'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', 'Color', 'black');
        drawnow;
        frame = getframe(fig, [0 0 160 320]);
        gray = rgb2gray(frame.cdata);
        templates{i} = imresize(gray, [32, 16]);
        templates{i} = imbinarize(templates{i});
        close(fig);
    end
    save(template_file, 'templates');
end

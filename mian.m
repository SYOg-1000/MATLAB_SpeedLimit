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
    
    if isempty(roi_cells)
        fprintf('  -> [定位] 终极兜底也未检出 ROI，图像中无红色圆状区域。\n');
        return;
    end
    
    ql = sign_metas{1}.quality_level;
    level_label = {'严格', '放宽', '很宽', '兜底'};
    
    % ① 原始图像与 NMS 定位框
    subplot(2, 3, 1); imshow(origin_img);
    title(sprintf('① 原始图像与 NMS 定位框 [L%d-%s]', ql, level_label{ql})); hold on;
    colors_box = {'cyan', 'yellow', 'g', 'magenta'};
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
    subplot(2, 3, 3); imshow(mask_final);
    title(sprintf('③ 形态学纯化红色掩膜 [L%d]', ql));
    
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
        
        fprintf('  -> 标志 #%d [L%d]: 识别结果 = %s km/h (置信度: %.1f%%)\n', k, ql, speed_val, confidence*100);
        
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
    
    % CLAHE 增强: 极大改善暗光/过曝场景的对比度
    CLAHE_NumTiles = [8 8];
    CLAHE_ClipLimit = 0.01;
    V_enhanced = adapthisteq(V, 'NumTiles', CLAHE_NumTiles, 'ClipLimit', CLAHE_ClipLimit);
    
    % 红色双区间掩膜 (HSV 色相环 0 附近和 1 附近均为红色)
    % 放宽阈值以适应实际拍摄场景: 红圈更小、饱和度更低、亮度更暗
    mask_low  = (H <= 0.10) & (S > 0.25) & (V_enhanced > 0.10);
    mask_high = (H >= 0.90) & (S > 0.25) & (V_enhanced > 0.10);
    mask_union = mask_low | mask_high;
    
    % 形态学开运算消除孤立噪点 (缩小半径避免抹除小红圈细边)
    mask_red = imopen(mask_union, strel('disk', 1));
end

% =========================================================================
% 模块 B: 多准则连通域筛选 + IoU-NMS (4级渐进松弛)
%   L1: 严格参数, 适合标准清晰大标志
%   L2: 放宽形态学面积和几何约束
%   L3: 大幅放宽所有几何约束
%   L4: 终极兜底, 保证不返回空 (识别模块做最终判断)
% =========================================================================
function [roi_cells, roi_bboxes, mask_final, sign_metas] = locate_signs_robust(origin_img, mask_red)
    roi_cells = {}; roi_bboxes = {}; sign_metas = {};
    
    [img_h, img_w, ~] = size(origin_img);
    red_density = sum(mask_red(:)) / (img_h * img_w);
    
    close_radii  = [0,   15,  20,  25];  % 0=L1自适应
    abs_areas    = [200, 100, 50,  20];
    rel_areas    = [0.05, 0.02, 0.01, 0];
    extents      = [0.45, 0.35, 0.25, 0.15];
    max_ars      = [2.5,  3.5,  5.0,  10.0];
    min_circs    = [0.40, 0.25, 0.10, 0.05];
    
    quality_level = 4;
    final_idx = [];
    final_stats = [];
    
    for level = 1:4
        if level == 1
            if red_density < 0.005
                close_r = 12;
            else
                close_r = 8;
            end
        else
            close_r = close_radii(level);
        end
        
        mask_closed = imclose(mask_red, strel('disk', close_r));
        mask_filled = imfill(mask_closed, 'holes');
        
        if level == 1
            mask_final = mask_filled;
        end
        
        stats = regionprops(mask_filled, 'Area', 'BoundingBox', 'Perimeter', 'Extent', 'MajorAxisLength', 'MinorAxisLength');
        if isempty(stats), continue; end
        
        max_area = max([stats.Area]);
        candidate_idx = [];
        
        for i = 1:length(stats)
            A = stats(i).Area; P = stats(i).Perimeter; Ext = stats(i).Extent;
            if P < 1, continue; end
            circ = (4 * pi * A) / (P^2);
            AR = stats(i).MajorAxisLength / max(stats(i).MinorAxisLength, 1);
            
            if (A > abs_areas(level)) && (A > max_area * rel_areas(level)) ...
               && (Ext > extents(level)) && (AR < max_ars(level)) && (circ > min_circs(level))
                candidate_idx(end+1) = i;
            end
        end
        
        if ~isempty(candidate_idx)
            cand_stats = stats(candidate_idx);
            bboxes_mat = vertcat(cand_stats.BoundingBox);
            areas_mat = [cand_stats.Area];
            fprintf('NMS前候选框数=%d\n', size(bboxes_mat, 1));
            keep_flags = nms_boxes(bboxes_mat, areas_mat, 0.70);
            final_idx = candidate_idx(keep_flags);
            
            if ~isempty(final_idx)
                fprintf('最终检测框数=%d\n', length(final_idx));
                disp(bboxes_mat(keep_flags, :));
                mask_final = mask_filled;
                final_stats = stats;
                quality_level = level;
                break;
            end
        end
    end
    
    if isempty(final_idx)
        return;
    end
    
    [H_img, W_img, ~] = size(origin_img);
    PAD = 15;
    for i = 1:length(final_idx)
        si = final_stats(final_idx(i)); bb = si.BoundingBox;
        x1 = max(floor(bb(1)) - PAD, 1);          y1 = max(floor(bb(2)) - PAD, 1);
        x2 = min(floor(bb(1) + bb(3)) + PAD, W_img); y2 = min(floor(bb(2) + bb(4)) + PAD, H_img);
        
        roi_cells{end+1} = origin_img(y1:y2, x1:x2, :);
        roi_bboxes{end+1} = [x1, y1, x2-x1, y2-y1];
        
        circ_k = (4*pi*si.Area) / max(si.Perimeter^2, 1);
        sign_metas{end+1} = struct('aspect_ratio', si.MajorAxisLength/max(si.MinorAxisLength,1), ...
                                   'circularity', circ_k, 'quality_level', quality_level);
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
% 过滤策略: 宽松初筛 -> Y一致性聚类 -> 宽度一致性聚类
% =========================================================================
function [char_cells, bw_clean] = segment_chars(roi_img)
    char_cells = {};
    gray_img = rgb2gray(roi_img);
    
    bw = ~imbinarize(gray_img, graythresh(gray_img));
    
    bw_clean = imclearborder(bw);
    bw_clean = bwareaopen(bw_clean, 30);
    
    [img_h, img_w] = size(bw_clean);
    mid_y = img_h / 2;
    
    stats = regionprops(bw_clean, 'BoundingBox', 'Area', 'Centroid');
    if isempty(stats), return; end
    
    cand_bboxes = [];
    cand_cent_y = [];
    max_a = max([stats.Area]);
    for i = 1:length(stats)
        bb = stats(i).BoundingBox;
        ratio = bb(4) / bb(3);
        if stats(i).Area <= max_a * 0.15 || ratio < 0.60
            continue;
        end
        
        cent_y = stats(i).Centroid(2);
        if abs(cent_y - mid_y) > img_h * 0.40
            continue;
        end
        
        cand_bboxes = [cand_bboxes; bb];
        cand_cent_y = [cand_cent_y; cent_y];
    end
    
    if isempty(cand_bboxes), return; end
    
    n_cand = size(cand_bboxes, 1);
    if n_cand > 2
        bbox_areas = cand_bboxes(:, 3) .* cand_bboxes(:, 4);
        [~, anchor_idx] = max(bbox_areas);
        anchor_y = cand_cent_y(anchor_idx);
        avg_w = mean(cand_bboxes(:, 3));
        
        keep = true(n_cand, 1);
        for i = 1:n_cand
            if abs(cand_cent_y(i) - anchor_y) > img_h * 0.15
                keep(i) = false;
                continue;
            end
            if cand_bboxes(i, 3) < avg_w * 0.45
                keep(i) = false;
            end
        end
        
        cand_bboxes = cand_bboxes(keep, :);
        if isempty(cand_bboxes), return; end
    end
    
    [~, sort_idx] = sort(cand_bboxes(:, 1));
    cand_bboxes = cand_bboxes(sort_idx, :);
    
    for i = 1:size(cand_bboxes, 1)
        bb = cand_bboxes(i, :);
        x = max(floor(bb(1))-1, 1); y = max(floor(bb(2))-1, 1);
        w = min(ceil(bb(3))+2, size(bw_clean,2)-x); h = min(ceil(bb(4))+2, size(bw_clean,1)-y);
        
        char_img = bw_clean(y:y+h, x:x+w);
        char_cells{i} = imresize(char_img, [32, 16], 'nearest');
    end
end

% =========================================================================
% 模块 F: 模板匹配核心 (corr2)
% 第三层过滤: 低置信度字符拒绝，防止非数字字符混入识别结果
% =========================================================================
function [speed_val, confidence] = recognize_digits(char_cells, templates)
    speed_val = '';
    conf_list = [];
    
    for i = 1:length(char_cells)
        test_char = char_cells{i};
        max_corr = -1;
        best_digit = '?';
        
        fprintf('\n===== 字符%d =====\n', i);
        for num = 0:9
            tpl = templates{num + 1};
            r = corr2(test_char, tpl);
            fprintf('%d : %.4f\n', num, r);
            if r > max_corr
                max_corr = r;
                best_digit = num2str(num);
            end
        end
        
        if max_corr < 0.15
            best_digit = '?';
        end
        
        speed_val = [speed_val, best_digit];
        conf_list(end+1) = max_corr;
    end
    
    if contains(speed_val, '?')
        confidence = 0;
    else
        confidence = mean(conf_list);
    end
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

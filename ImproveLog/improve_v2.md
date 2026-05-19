# 限速标志识别系统 - 对话优化记录 v2

> 本文档记录本次对话中对 `mian.m` 的所有修改。

---

## 一、大问题（本次对话总体需求）

当前代码对标准限速图识别良好，但**实际拍摄图片中小尺寸红色标志无法检测**，ROI 模块直接返回空，识别流程无法继续。

**需求**：
1. 增强对小尺寸、低饱和度红色标志的检测能力
2. 重构 ROI 模块，保证**永远返回至少一个候选区域**（哪怕是噪声）
3. 识别模块（而非定位模块）做最终"是否是有效限速标志"的判断

---

## 二、小问题（本次对话具体实践）

### 小问题 1：红色掩膜提取失败（小标志）
- **现象**：实际拍摄图片中，红色圆圈小，饱和度低，经形态学处理后几乎没有残留像素
- **根因**：
  - HSV 阈值过于严格：`H ≤ 0.08` / `H ≥ 0.92`，`S > 0.35`，`V > 0.15`
  - 形态学开运算半径 `disk=2` 过大，抹除了小标志的边缘
  - 面积阈值 `> 200` 对极小标志太高
- **临时修复**：先放宽了 HSV 阈值和形态学参数，但发现还是无法保证 100% 有 ROI

### 小问题 2：需要渐进式检测保证返回
- **现象**：放宽参数后，部分极小图仍可能漏检，或标准图过度放宽引入噪声
- **根因**：单轮检测无法同时兼顾"标准图低噪声"和"极小图必检测"
- **解决方案**：4级渐进式检测，从严格到宽松，直到找到 ROI 为止

---

## 三、最终实施方案

### 模块 A：红色流形分割 [color_segment_red](file:///d:/ADraft/AAA_PROJECT/MATLAB_SpeedLimit/mian.m#L164-L184)
| 参数 | 修改前 | 修改后 |
|------|--------|--------|
| 低 H 阈值 | `H ≤ 0.08` | `H ≤ 0.10` |
| 高 H 阈值 | `H ≥ 0.92` | `H ≥ 0.90` |
| S 下限 | `> 0.35` | `> 0.25` |
| V 下限 | `> 0.15` | `> 0.10` |
| 开运算半径 | `disk=2` | `disk=1` |
| CLAHE ClipLimit | 0.02 | 0.01 |

### 模块 B：4级渐进式定位 [locate_signs_robust](file:///d:/ADraft/AAA_PROJECT/MATLAB_SpeedLimit/mian.m#L193-L280)
重构为**4级循环检测**：

| Level | close_r | abs_area | rel_area | extent | AR | circ | 说明 |
|-------|---------|----------|----------|--------|----|------|------|
| L1 严格 | 自适应 8/12 | 200 | 0.05 | 0.45 | 2.5 | 0.40 | 标准大标志 |
| L2 放宽 | 15 | 100 | 0.02 | 0.35 | 3.5 | 0.25 | 较小标志 |
| L3 很宽 | 20 | 50 | 0.01 | 0.25 | 5.0 | 0.10 | 小标志 |
| L4 兜底 | 25 | 20 | 0 | 0.15 | 10.0 | 0.05 | 极小标志/噪声 |

### 模块 C：可视化增强 [process_single_image](file:///d:/ADraft/AAA_PROJECT/MATLAB_SpeedLimit/mian.m#L68-L159)
1. 添加质量等级显示：`[L1-严格]` / `[L4-兜底]`
2. 移除早期空 ROI 返回，仅在 4 级全失败时才返回
3. 在 `sign_metas` 结构体中新增 `quality_level` 字段记录检测层级

---

## 四、代码变更

### 4.1 color_segment_red 函数（[mian.m#L164-L184](file:///d:/ADraft/AAA_PROJECT/MATLAB_SpeedLimit/mian.m#L164-L184)）
```matlab
% 修改前（严格阈值）
mask_low  = (H <= 0.08) & (S > 0.35) & (V_enhanced > 0.15);
mask_high = (H >= 0.92) & (S > 0.35) & (V_enhanced > 0.15);
mask_red = imopen(mask_union, strel('disk', 2));

% 修改后（放宽阈值）
mask_low  = (H <= 0.10) & (S > 0.25) & (V_enhanced > 0.10);
mask_high = (H >= 0.90) & (S > 0.25) & (V_enhanced > 0.10);
mask_red = imopen(mask_union, strel('disk', 1));
CLAHE_ClipLimit = 0.01;  % 从 0.02 降低
```

### 4.2 locate_signs_robust 函数（[mian.m#L193-L280](file:///d:/ADraft/AAA_PROJECT/MATLAB_SpeedLimit/mian.m#L193-L280)）
```matlab
% 完全重写：从单轮检测改为 4 级渐进循环

% 新增：4 级参数数组
close_radii  = [0,   15,  20,  25];
abs_areas    = [200, 100, 50,  20];
rel_areas    = [0.05, 0.02, 0.01, 0];
extents      = [0.45, 0.35, 0.25, 0.15];
max_ars      = [2.5,  3.5,  5.0,  10.0];
min_circs    = [0.40, 0.25, 0.10, 0.05];

% 新增：循环检测
for level = 1:4
    % 选择当前 level 的参数
    if level == 1
        close_r = 自适应值;
    else
        close_r = close_radii(level);
    end
    
    % 形态学 + 连通域筛选 + NMS
    mask_closed = imclose(mask_red, strel('disk', close_r));
    mask_filled = imfill(mask_closed, 'holes');
    stats = regionprops(...);
    
    % 筛选...
    
    if ~isempty(candidate_idx) && ~isempty(final_idx)
        % 找到，记录质量等级并 break
        quality_level = level;
        break;
    end
end

% 新增：sign_metas 中记录 quality_level
sign_metas{end+1} = struct(..., 'quality_level', quality_level);
```

### 4.3 process_single_image 函数（[mian.m#L68-L159](file:///d:/ADraft/AAA_PROJECT/MATLAB_SpeedLimit/mian.m#L68-L159)）
```matlab
% 新增：质量等级显示
ql = sign_metas{1}.quality_level;
level_label = {'严格', '放宽', '很宽', '兜底'};

% 修改：标题加入质量等级
title(sprintf('① 原始图像与 NMS 定位框 [L%d-%s]', ql, level_label{ql}));

% 修改：日志加入质量等级
fprintf('  -> 标志 #%d [L%d]: 识别结果 = %s km/h (置信度: %.1f%%)\n', k, ql, speed_val, confidence*100);

% 修改：空 ROI 判断移到最前面，仅在 4 级全失败时返回
if isempty(roi_cells)
    fprintf('  -> [定位] 终极兜底也未检出 ROI，图像中无红色圆状区域。\n');
    return;
end
```

---

## 五、关键参数索引

| 参数 | 位置 | 当前值 | 说明 |
|------|------|--------|------|
| H 低阈值 | color_segment_red L178 | 0.10 | 从 0.08 放宽 |
| H 高阈值 | color_segment_red L179 | 0.90 | 从 0.92 放宽 |
| S 下限 | color_segment_red L178-L179 | 0.25 | 从 0.35 放宽 |
| V 下限 | color_segment_red L178-L179 | 0.10 | 从 0.15 放宽 |
| 开运算半径 | color_segment_red L183 | 1 | 从 2 缩小 |
| CLAHE ClipLimit | color_segment_red L173 | 0.01 | 从 0.02 降低 |
| L1 面积下限 | locate_signs_robust L200 | 200 | 严格 |
| L4 面积下限 | locate_signs_robust L200 | 20 | 兜底 |
| L4 extent 下限 | locate_signs_robust L202 | 0.15 | 极低 |
| L4 AR 上限 | locate_signs_robust L203 | 10.0 | 极宽 |
| L4 circ 下限 | locate_signs_robust L204 | 0.05 | 极低 |

---

## 六、解决的问题

### 问题 1：小尺寸红色标志检测失败
- **现象**：实际拍摄图中，标志小，饱和度低，定位模块返回空
- **修复**：4级渐进检测，L4 兜底保证必返回

### 问题 2：定位模块过早返回空
- **现象**：定位失败后直接退出，没有后续处理
- **修复**：移除早期空返回，识别模块作为最终判断

### 问题 3：标准图受影响（过度放宽）
- **现象**：若直接用最宽松参数，标准图会引入大量噪声
- **修复**：4级渐进，严格参数先尝试，不命中再放宽

---

## 七、文件清单

| 文件路径 | 说明 |
|----------|------|
| `mian.m` | 主程序，含 color_segment_red、locate_signs_robust、process_single_image 修改 |
| `.trae/documents/progressive_relaxation_roi_plan.md` | 渐进式检测方案计划书 |

---

*生成日期：2026-05-20*

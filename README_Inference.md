# Inference View

The inference view lets you run a point-conditioned CoreML policy on-device, visualize actions in AR, and inspect the gripper state. The purpose of this is to allow for us to be able to test the model without a robot, and get a sense of it's capability(vibe) with you acting as a robot arm, and evaluating in the wild based on the policy's conditioning task. It is optimized for low-latency inference and small memory churn using shared pixel buffers and Accelerate for preprocessing.

## Model Assumptions

- CoreML model (converted from RUM/min-stretch pipeline).
- RGB input resized to 224×224 today (code path); original spec 256×256—adjust `modelInputSize`/buffers in `MLInferenceManager` if your model truly requires 256.
- Temporal window: 3 frames (rolling action buffer).
- Inputs: image tensor `[1, 3, H, W]` or `[1, T, 3, H, W]` plus goal tensor (3D point; shape inferred from the model).
- Output: 7 floats (6-DoF action + gripper scalar at index 6). Temporal outputs use the last timestep.

## Pipeline (MLInferenceManager)

1) **Model load**: `ModelManager` provides the active compiled model and metadata (temporal frames, input/output names, goal requirement). A loading overlay is shown while this warms up.  
2) **Goal conditioning**: A user-tapped 3D goal in world space is transformed to the camera/labels frame just before inference (mapping: `[-x_cam, -z_cam + first-frame 0.02 offset, -y_cam]`). Required models skip inference until a goal exists.  
3) **Frame prep**: AR camera frames → vImage/Core Image resize to 224×224 ARGB → normalized MLMultiArray `[1,3,H,W]`. Gripper overlay is composited into the model input when USB streaming is OFF.  
4) **Temporal buffer**: Maintain up to 3 action frames.  
   - USB streaming ON: always roll the buffer; run by frequency (High/Med/Low/Minute) or first inference.  
   - USB streaming OFF (recording mode): buffer only when proximity trigger fires or on first/manual inference.  
5) **Input packing**: Build `[1,T,3,H,W]` with padding if fewer than T frames; build goal tensor matching the model-declared shape; assemble `MLDictionaryFeatureProvider`.  
6) **Inference**: Run off-main on a dedicated queue; track inference time; guard with a pending flag to avoid overlap.  
7) **Postprocess**: Extract joint actions (last timestep if temporal). Gripper value updates UI + overlay, and AR visualization updates the target pose (skipped in USB mode). Latest result is published for the UI card.

## UI/Controls (InferenceView)

- **Set goal**: Tap “Set goal”, then tap in AR to place the 3D target.  
- **Start/stop**: App toggle enables/disables inference; model loading overlay appears when switching models.  
- **Manual step**: “Get next action” calls manual inference using the buffered frames.  
- **Modes**:  
  - Recording mode (USB off): proximity trigger or manual step drives inference.  
  - USB streaming: continuous buffer + frequency-based inference; gripper overlay is skipped in the model input because the real gripper is present.  
- **Visualization**: AR overlay shows the inferred pose (recording mode only). Gripper overlay image on-screen mirrors predicted gripper open/closed and shows an “iPhone Inferencing” badge when active.  
- **Status card**: `MLInferenceResultsView` shows gripper value and OPEN/CLOSED state; “Analyzing…” while waiting for first result.  
- **Other controls**: Record/stop capture, delete last recording (with confirm), flash toggle, grid overlay toggle, Bluetooth status bar.

## How to Use Quickly

1) Ensure a compiled model is available (see min-stretch conversion flow) and enter the Inference tab.  
2) Enable inference; wait for “Preparing Model…” to finish if shown.  
3) Tap “Set goal” and place the target in AR.  
4) Press Record (or leave USB streaming on) and either approach the goal (proximity trigger) or tap “Get next action.”  
5) Watch the AR pose updates (recording mode) and the gripper card/overlay for state and timing feedback.

## Notes for Researchers

- Temporal window and goal handling match the training assumptions: three recent frames plus a 3D goal mapped into the labels frame.  
- Current resize is 224×224; if your model was exported for 256×256, update `modelInputSize`, shared buffers, and processing paths accordingly.  
- Gripper is treated as a continuous scalar; UI thresholds `<0.7` as CLOSED.  
- Inference frequency can be throttled to study latency/throughput tradeoffs; visualization frequency is synchronized to the chosen inference cadence.  
- Debug hooks: optional frame saves, transform debug prints, and detailed console logs around buffering, padding, and overlay application.

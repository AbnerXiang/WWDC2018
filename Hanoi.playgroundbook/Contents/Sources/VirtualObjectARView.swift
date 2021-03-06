import Foundation
import ARKit

public class VirtualObjectARView: ARSCNView {
    
    // MARK: - 类型
    public struct HitTestRay {
        var origin: float3
        var direction: float3
        
        public func intersectionWithHorizontalPlane(atY planeY: Float) -> float3? {
            let normalizedDirection = simd_normalize(direction)
            
            // 特殊情况处理:检查射线是否也是水平的.
            if normalizedDirection.y == 0 {
                if origin.y == planeY {
                    /*
                     射线是水平的,且位于平面上,这样射线上所有的点都和平面相交.因此我们简单地返回射线原点坐标.
                     */
                    return origin
                } else {
                    // 射线平行于平面但不相交.
                    return nil
                }
            }
            
            /*
             从射线原点到与平面交点的距离公式是:横线代表分数线,点乘即:点积,数量积
             (交点-射线原点)点乘(平面法线)
             -------------------------除以
             (方向)点乘(平面法线)
             */
            
            // 因为我们已经知道水平面的法线是(0,1,0),即点乘后只有y值保留且倍数不变,我们可以简化公式为:
            let distance = (planeY - origin.y) / normalizedDirection.y
            
            // 不要返回射线原点后面的交点.
            if distance < 0 {
                return nil
            }
            
            // 返回交点.
            return origin + (normalizedDirection * distance)
        }
        
    }
    
    public struct FeatureHitTestResult {
        var position: float3
        var distanceToRayOrigin: Float
        var featureHit: float3
        var featureDistanceToHitResult: Float
    }
    
    /**
     从指定的屏幕位置发起命中测试,返回最精确的结果.
     返回新世界坐标位置,命中平面的锚点.
     */
    public func worldPosition(fromScreenPosition position: CGPoint, objectPosition: float3?, infinitePlane: Bool = false) -> (position: float3, planeAnchor: ARPlaneAnchor?, isOnPlane: Bool)? {
        
        // 方法1.优先对已存在的平面锚点进行命中测试.(如果有锚点存在&在他们的范围内)
        let planeHitTestResults = hitTest(position, types: .existingPlaneUsingExtent)
        
        if let result = planeHitTestResults.first {
            let planeHitTestPosition = result.worldTransform.translation
            let planeAnchor = result.anchor
            
            // 直接返回 - 这是最佳的输出.
            return (planeHitTestPosition, planeAnchor as? ARPlaneAnchor, true)
        }
        
        // 方法2.根据命中测试遇到的特征点云,收集更多环境信息,但是暂不返回结果.
        let featureHitTestResult = hitTestWithFeatures(position, coneOpeningAngleInDegrees: 18, minDistance: 0.2, maxDistance: 2.0).first
        let featurePosition = featureHitTestResult?.position
        
        // 方法3. 如果需要的话(没有发现足够好的特征命中测试结果):命中测试遇到一个无限大的水平面(忽略真实世界).
        if infinitePlane || featurePosition == nil {
            if let objectPosition = objectPosition,
                let pointOnInfinitePlane = hitTestWithInfiniteHorizontalPlane(position, objectPosition) {
                return (pointOnInfinitePlane, nil, true)
            }
        }
        
        // 方法4. 如果可用的话,当命中测试遇到无限平面被忽略或者没有遇到无限平面,则返回命中测试遇到的高质量特征点.
        if let featurePosition = featurePosition {
            return (featurePosition, nil, false)
        }
        
        // 方法5. 最后万不得已时,执行备份方案,返回未过滤的命中测试遇到的特征点.如果场景中没有特征点,返回结果将是nil.
        let unfilteredFeatureHitTestResults = hitTestWithFeatures(position)
        if let result = unfilteredFeatureHitTestResults.first {
            return (result.position, nil, false)
        }
        
        return nil
    }
    
    // MARK: -  命中测试
    public func hitTestRayFromScreenPosition(_ point: CGPoint) -> HitTestRay? {
        guard let frame = session.currentFrame else { return nil }
        
        let cameraPos = frame.camera.transform.translation
        
        // 注意: z: 1.0将会反投影屏幕位置到远裁剪平面上.
        let positionVec = float3(x: Float(point.x), y: Float(point.y), z: 1.0)
        let screenPosOnFarClippingPlane = unprojectPoint(positionVec)
        
        let rayDirection = simd_normalize(screenPosOnFarClippingPlane - cameraPos)
        return HitTestRay(origin: cameraPos, direction: rayDirection)
    }
    
    // 用于方法2
    public func hitTestWithFeatures(_ point: CGPoint, coneOpeningAngleInDegrees: Float, minDistance: Float = 0, maxDistance: Float = Float.greatestFiniteMagnitude, maxResults: Int = 1) -> [FeatureHitTestResult] {
        
        guard let features = session.currentFrame?.rawFeaturePoints, let ray = hitTestRayFromScreenPosition(point) else {
            return []
        }
        
        let maxAngleInDegrees = min(coneOpeningAngleInDegrees, 360) / 2
        let maxAngle = (maxAngleInDegrees / 180) * .pi
        
        let results = features.points.flatMap { featurePosition -> FeatureHitTestResult? in
            let originToFeature = featurePosition - ray.origin
            
            let crossProduct = simd_cross(originToFeature, ray.direction)
            let featureDistanceFromResult = simd_length(crossProduct)
            
            let hitTestResult = ray.origin + (ray.direction * simd_dot(ray.direction, originToFeature))
            let hitTestResultDistance = simd_length(hitTestResult - ray.origin)
            
            if hitTestResultDistance < minDistance || hitTestResultDistance > maxDistance {
                // 忽略这个特征 - 太近或者太远.
                return nil
            }
            
            let originToFeatureNormalized = simd_normalize(originToFeature)
            let angleBetweenRayAndFeature = acos(simd_dot(ray.direction, originToFeatureNormalized))
            
            if angleBetweenRayAndFeature > maxAngle {
                // 忽略这个特征 - 超出了命中测试圆锥体
                return nil
            }
            
            // 所有测试通过: 将遇到这个特征点的命中测试添加到结果中.
            return FeatureHitTestResult(position: hitTestResult,
                                        distanceToRayOrigin: hitTestResultDistance,
                                        featureHit: featurePosition,
                                        featureDistanceToHitResult: featureDistanceFromResult)
        }
        
        // 根据特征点到射线的距离,给结果排序.
        let sortedResults = results.sorted { $0.distanceToRayOrigin < $1.distanceToRayOrigin }
        
        let remainingResults = sortedResults.dropFirst(maxResults)
        
        return Array(remainingResults)
    }
    
    // 用于方法3
    public func hitTestWithInfiniteHorizontalPlane(_ point: CGPoint, _ pointOnPlane: float3) -> float3? {
        guard let ray = hitTestRayFromScreenPosition(point) else { return nil }
        
        // 不和摄像机上方的平面相交,或射线几乎平行与平面.
        if ray.direction.y > -0.03 {
            return nil
        }
        
        /*
         返回从屏幕的摄像机处发出的射线与某个水平面(Y轴)的交点.
         */
        return ray.intersectionWithHorizontalPlane(atY: pointOnPlane.y)
    }
    
    // 用于方法5
    public func hitTestWithFeatures(_ point: CGPoint) -> [FeatureHitTestResult] {
        guard let features = session.currentFrame?.rawFeaturePoints,
            let ray = hitTestRayFromScreenPosition(point) else {
                return []
        }
        
        /*
         找到离命中测试射线最近的特征点,然后通过找到射线上距离特征点最近的点,来创建一个命中测试结果.
         */
        let possibleResults = features.points.map { featurePosition in
            return FeatureHitTestResult(featurePoint: featurePosition, ray: ray)
        }
        let closestResult = possibleResults.min(by: { $0.featureDistanceToHitResult < $1.featureDistanceToHitResult })!
        return [closestResult]
    }
    
}

public extension SCNView {
    /*
     对`unprojectPoint(_:)`封装后的便利方法.
     用在SIMD float3类型相关的方法里.
     */
    func unprojectPoint(_ point: float3) -> float3 {
        return float3(unprojectPoint(SCNVector3(point)))
    }
}

extension VirtualObjectARView.FeatureHitTestResult {

    // 给`FeatureHitTestResult`添加一个`HitTestRay`的便利构造器.
    // 在扩展中添加构造器,同时也得到了`FeatureHitTestResult`的默认构造器.
    init(featurePoint: float3, ray: VirtualObjectARView.HitTestRay) {
        self.featureHit = featurePoint
        
        let originToFeature = featurePoint - ray.origin
        self.position = ray.origin + (ray.direction * simd_dot(ray.direction, originToFeature))
        self.distanceToRayOrigin = simd_length(self.position - ray.origin)
        self.featureDistanceToHitResult = simd_length(simd_cross(originToFeature, ray.direction))
    }
}


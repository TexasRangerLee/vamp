Shader "Hidden/blur"
{
	Properties
	{
        _MainTex("Texture", any) = "" {}
	}
		SubShader
	{
		// No culling or depth
		Cull Off ZWrite Off ZTest Always

		CGINCLUDE

		#define PI 3.1415927f

#include "UnityCG.cginc"	

        UNITY_DECLARE_TEX2D(_CameraDepthTexture);        
        UNITY_DECLARE_TEX2D(_HalfResDepthBuffer);        
        UNITY_DECLARE_TEX2D(_HalfResColor);
        UNITY_DECLARE_TEX2D(_MainTex);

        float4 _CameraDepthTexture_TexelSize;
        float4 _HalfResDepthBuffer_TexelSize;
        
		struct appdata
		{
			float4 vertex : POSITION;
			float2 uv : TEXCOORD0;
		};

		struct v2f
		{
			float2 uv : TEXCOORD0;
			float4 vertex : SV_POSITION;
		};

		struct v2fDownsample
		{
			float2 uv : TEXCOORD0;
			float4 vertex : SV_POSITION;
		};

		struct v2fUpsample
		{
			float2 uv : TEXCOORD0;
			float2 uv00 : TEXCOORD1;
			float2 uv01 : TEXCOORD2;
			float2 uv10 : TEXCOORD3;
			float2 uv11 : TEXCOORD4;
			float4 vertex : SV_POSITION;
		};

		v2f vert(appdata v)
		{
			v2f o;
			o.vertex = mul(UNITY_MATRIX_MVP, v.vertex);
			o.uv = v.uv;
			return o;
		}

		//-----------------------------------------------------------------------------------------
		// vertDownsampleDepth
		//-----------------------------------------------------------------------------------------
		v2fDownsample vertDownsampleDepth(appdata v, float2 texelSize)
		{
			v2fDownsample o;
			o.vertex = mul(UNITY_MATRIX_MVP, v.vertex);
			o.uv = v.uv;
			return o;
		}

		//-----------------------------------------------------------------------------------------
		// vertUpsample
		//-----------------------------------------------------------------------------------------
        v2fUpsample vertUpsample(appdata v, float2 texelSize)
        {
            v2fUpsample o;
            o.vertex = mul(UNITY_MATRIX_MVP, v.vertex);
            o.uv = v.uv;

            o.uv00 = v.uv - 0.5 * texelSize.xy;
            o.uv10 = o.uv00 + float2(texelSize.x, 0);
            o.uv01 = o.uv00 + float2(0, texelSize.y);
            o.uv11 = o.uv00 + texelSize.xy;
            return o;
        }

		//-----------------------------------------------------------------------------------------
		// BilateralUpsample
		//-----------------------------------------------------------------------------------------
		float4 BilateralUpsample(v2fUpsample input, Texture2D hiDepth, Texture2D loDepth, Texture2D loColor, SamplerState linearSampler, SamplerState pointSampler)
		{
            const float threshold = 1.5f;
            float4 highResDepth = LinearEyeDepth(hiDepth.Sample(pointSampler, input.uv)).xxxx;
			float4 lowResDepth;

            lowResDepth[0] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv00));
            lowResDepth[1] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv10));
            lowResDepth[2] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv01));
            lowResDepth[3] = LinearEyeDepth(loDepth.Sample(pointSampler, input.uv11));

			float4 depthDiff = abs(lowResDepth - highResDepth);

			float accumDiff = dot(depthDiff, float4(1, 1, 1, 1));

			[branch]
			if (accumDiff < threshold) // small error, not an edge -> use bilinear filter
			{
				return loColor.Sample(linearSampler, input.uv);
			}
            
			// find nearest sample
			float minDepthDiff = depthDiff[0];
			float2 nearestUv = input.uv00;

			if (depthDiff[1] < minDepthDiff)
			{
				nearestUv = input.uv10;
				minDepthDiff = depthDiff[1];
			}

			if (depthDiff[2] < minDepthDiff)
			{
				nearestUv = input.uv01;
				minDepthDiff = depthDiff[2];
			}

			if (depthDiff[3] < minDepthDiff)
			{
				nearestUv = input.uv11;
				minDepthDiff = depthDiff[3];
			}

            return loColor.Sample(pointSampler, nearestUv);
		}

		//-----------------------------------------------------------------------------------------
		// DownsampleDepth
		//-----------------------------------------------------------------------------------------
		float DownsampleDepth(v2fDownsample input, Texture2D depthTexture, SamplerState depthSampler)
		{
            float4 depth = depthTexture.Gather(depthSampler, input.uv);

			float minDepth = min(min(depth.x, depth.y), min(depth.z, depth.w));
			float maxDepth = max(max(depth.x, depth.y), max(depth.z, depth.w));

			// chessboard pattern
			int2 position = input.vertex.xy % 2;
			int index = position.x + position.y;
			return index == 1 ? minDepth : maxDepth;
		}
		
		//-----------------------------------------------------------------------------------------
		// GaussianWeight
		//-----------------------------------------------------------------------------------------
		float GaussianWeight(float offset, float deviation)
		{
			float weight = 1.0f / sqrt(2.0f * PI * deviation * deviation);
			weight *= exp(-(offset * offset) / (2.0f * deviation * deviation));
			return weight;
		}

		//-----------------------------------------------------------------------------------------
		// BilateralBlur
		//-----------------------------------------------------------------------------------------
		float4 BilateralBlur(v2f input, int2 direction, Texture2D depth, SamplerState depthSampler, const int kernelRadius, float2 pixelSize)
		{
			const float deviation = kernelRadius / 1.5f; // make it really strong

			float2 uv = input.uv;
			float4 centerColor = _MainTex.Sample(sampler_MainTex, uv);
			float3 color = centerColor.xyz;
			float centerDepth = (LinearEyeDepth(depth.Sample(depthSampler, uv)));

			float weightSum = 0;

			// gaussian weight is computed from constants only -> will be computed in compile time
            float weight = GaussianWeight(0, deviation);
			color *= weight;
			weightSum += weight;
						
			[unroll] for (int i = -kernelRadius; i < 0; i += 1)
			{
                float2 offset = (direction * i);
                float3 sampleColor = _MainTex.Sample(sampler_MainTex, input.uv, offset);
                float sampleDepth = (LinearEyeDepth(depth.Sample(depthSampler, input.uv, offset)));

				float depthDiff = abs(centerDepth - sampleDepth);
                float dFactor = depthDiff * 0.5f;
				float w = exp(-(dFactor * dFactor));

				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			[unroll] for (i = 1; i <= kernelRadius; i += 1)
			{
				float2 offset = (direction * i);
                float3 sampleColor = _MainTex.Sample(sampler_MainTex, input.uv, offset);
                float sampleDepth = (LinearEyeDepth(depth.Sample(depthSampler, input.uv, offset)));

				float depthDiff = abs(centerDepth - sampleDepth);
                float dFactor = depthDiff * 0.5f;
				float w = exp(-(dFactor * dFactor));
				
				// gaussian weight is computed from constants only -> will be computed in compile time
				weight = GaussianWeight(i, deviation) * w;

				color += weight * sampleColor;
				weightSum += weight;
			}

			color /= weightSum;
			return float4(color, centerColor.w);
		}

		ENDCG

		//Pass 0
		Pass 
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment horizontalFrag
            #pragma target 4.0

			fixed4 horizontalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input, int2(1, 0), _HalfResDepthBuffer, sampler_HalfResDepthBuffer, 5.0f, _HalfResDepthBuffer_TexelSize.xy);
		}

			ENDCG
		}

		//Pass 1
		Pass
		{
			CGPROGRAM
            #pragma vertex vert
            #pragma fragment verticalFrag
            #pragma target 4.0

			fixed4 verticalFrag(v2f input) : SV_Target
		{
            return BilateralBlur(input, int2(0, 1), _HalfResDepthBuffer, sampler_HalfResDepthBuffer, 5.0f, _HalfResDepthBuffer_TexelSize.xy);
		}

			ENDCG
		}

		// pass 2
		Pass
		{
			CGPROGRAM
			#pragma vertex vertHalfDepth
			#pragma fragment frag
            #pragma target gl4.1

			v2fDownsample vertHalfDepth(appdata v)
			{
                return vertDownsampleDepth(v, _CameraDepthTexture_TexelSize);
			}

			float frag(v2fDownsample input) : SV_Target
			{
                return DownsampleDepth(input, _CameraDepthTexture, sampler_CameraDepthTexture);
			}

			ENDCG
		}

		// pass 3
		Pass
		{
			Blend One Zero

			CGPROGRAM
			#pragma vertex vertUpsampleToFull
			#pragma fragment frag		
            #pragma target 4.0

			v2fUpsample vertUpsampleToFull(appdata v)
			{
                return vertUpsample(v, _HalfResDepthBuffer_TexelSize);
			}
			float4 frag(v2fUpsample input) : SV_Target
			{
				return BilateralUpsample(input, _CameraDepthTexture, _HalfResDepthBuffer, _HalfResColor, sampler_HalfResColor, sampler_HalfResDepthBuffer);
			}

			ENDCG
		}
	}
}

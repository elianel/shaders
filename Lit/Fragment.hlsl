#include "SurfaceData.hlsl"

half4 frag (v2f input, uint facing : SV_IsFrontFace) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input)
    SurfaceData surf;
    InitializeDefaultSurfaceData(surf);
    InitializeSurfaceData(surf, input, facing);

#if defined(UNITY_PASS_SHADOWCASTER)
    #if defined(_ALPHATEST_ON)
        if (surf.alpha < _Cutoff) discard;
    #endif

    #ifdef _ALPHAPREMULTIPLY_ON
        surf.alpha = lerp(surf.alpha, 1.0, surf.metallic);
    #endif

    #if defined(_ALPHAPREMULTIPLY_ON) || defined(_ALPHAFADE_ON)
        half dither = Unity_Dither(surf.alpha, input.pos.xy);
        if (dither < 0.0) discard;
    #endif

    SHADOW_CASTER_FRAGMENT(input);
#endif

    #if defined(_ALPHATEST_ON)
        AACutout(surf.alpha, _Cutoff);
    #endif

    surf.tangentNormal.g *= -1;
    FlipBTN(facing, input.worldNormal, input.bitangent, input.tangent);

    half3 indirectSpecular = 0.0;
    half3 directSpecular = 0.0;
    half3 indirectDiffuse = 0.0;

    #ifdef _GEOMETRICSPECULAR_AA
        surf.perceptualRoughness = GSAA_Filament(input.worldNormal, surf.perceptualRoughness);
    #endif
    
    TangentToWorldNormal(surf.tangentNormal, input.worldNormal, input.tangent, input.bitangent);

    float3 viewDir = normalize(UnityWorldSpaceViewDir(input.worldPos));
    half NoV = NormalDotViewDir(input.worldNormal, viewDir);

    half3 f0 = GetF0(surf);
    DFGLut = SampleDFG(NoV, surf.perceptualRoughness).rg;
    DFGEnergyCompensation = EnvBRDFEnergyCompensation(DFGLut, f0);

    LightData lightData;
    InitializeMainLightData(lightData, input.worldNormal, viewDir, NoV, surf.perceptualRoughness, f0, input);

    #if !defined(_SPECULARHIGHLIGHTS_OFF) && defined(USING_LIGHT_MULTI_COMPILE)
        directSpecular += lightData.Specular;
    #endif

    #if defined(VERTEXLIGHT_ON) && !defined(VERTEXLIGHT_PS)
        lightData.FinalColor += input.vertexLight;
    #endif

    #if defined(VERTEXLIGHT_PS) && defined(VERTEXLIGHT_ON)
        NonImportantLightsPerPixel(lightData.FinalColor, directSpecular, input.worldPos, input.worldNormal, viewDir, NoV, f0, surf.perceptualRoughness);
    #endif

    indirectDiffuse = GetIndirectDiffuseAndSpecular(input, surf, directSpecular, f0, input.worldNormal, viewDir, NoV, lightData);

    #if !defined(_GLOSSYREFLECTIONS_OFF)
        indirectSpecular += GetReflections(input.worldNormal, input.worldPos.xyz, viewDir, f0, NoV, surf, indirectDiffuse);
    #endif

    #ifdef LTCGI_INCLUDED
        float2 ltcgi_lmuv;
        #if defined(LIGHTMAP_ON)
            ltcgi_lmuv = input.uv[1].xy * unity_LightmapST.xy + unity_LightmapST.zw;
        #else
            ltcgi_lmuv = float2(0, 0);
        #endif

        float3 ltcgiSpecular = 0;
        LTCGI_Contribution(input.worldPos, input.worldNormal, viewDir, surf.perceptualRoughness, ltcgi_lmuv, indirectDiffuse
            #ifndef SPECULAR_HIGHLIGHTS_OFF
                    , ltcgiSpecular
            #endif
        );
        indirectSpecular += ltcgiSpecular;
    #endif

    #ifdef SHADER_API_MOBILE
        indirectSpecular = indirectSpecular * EnvBRDFApprox(surf.perceptualRoughness, NoV, f0);
    #else
        indirectSpecular = indirectSpecular * DFGEnergyCompensation * EnvBRDFMultiscatter(DFGLut, f0);
    #endif

    #if defined(_ALPHAPREMULTIPLY_ON)
        surf.albedo.rgb *= surf.alpha;
        surf.alpha = lerp(surf.alpha, 1.0, surf.metallic);
    #endif

    #if defined(_ALPHAMODULATE_ON)
        surf.albedo.rgb = lerp(1.0, surf.albedo.rgb, surf.alpha);
    #endif

    half4 finalColor = half4(surf.albedo.rgb * (1.0 - surf.metallic) * (indirectDiffuse * surf.occlusion + (lightData.FinalColor))
                     + indirectSpecular + directSpecular + surf.emission, surf.alpha);

    #ifdef UNITY_PASS_META
        UnityMetaInput metaInput;
        UNITY_INITIALIZE_OUTPUT(UnityMetaInput, metaInput);
        metaInput.Emission = surf.emission;
        metaInput.Albedo = surf.albedo.rgb;
        return float4(UnityMetaFragment(metaInput).rgb, surf.alpha);
    #endif

    
    UNITY_APPLY_FOG(input.fogCoord, finalColor);
    
    #ifdef ACES_TONEMAPPING
        UNITY_FLATTEN
        if (!isReflectionProbe())
        {
            finalColor.rgb = ACESFitted(finalColor.rgb);
        }
    #endif

    #ifndef SHADER_API_MOBILE
        #ifdef DITHERING
            finalColor.rgb -= ditherNoiseFuncHigh(input.uv[1].xy) * 0.001;
        #else
            // the reason why this exists is because post processing doesnt handle black colors properly
            // only visible with OLED displays, black colors are gray
            // shifts the colors down a bit so when the post processing dithering is applied it keeps the blacks
            // doesnt fix all post processing effects 
            finalColor.rgb -= 0.0002;
        #endif
    #endif

    return finalColor;
}
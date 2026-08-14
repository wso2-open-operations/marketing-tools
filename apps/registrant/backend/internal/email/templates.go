// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

package email

// RegistrantInvitationTemplate is the registrant invitation email's HTML
// body. Bind QR_IMAGE and WALLET_PASS_LINK via BindKeyValues before sending.
const RegistrantInvitationTemplate = `
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">

<head>
	<meta content="text/html; charset=utf-8" http-equiv="Content-Type" />
	<!-- Facebook sharing information tags -->
	<meta property="og:title" content="{{subject}}" />
	<meta name="color-scheme" content="light dark">
	<meta name="supported-color-schemes" content="light dark">

	<title>Your WSO2Con Asia 2025 Digital Pass is Here!</title>

	<!--[if mso]>
      <style type="text/css">
        @font-face {font-family: 'Plus Jakarta Sans';font-style: normal;font-weight: 100;font-display: swap;src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/Plus Jakarta Sans/Plus Jakarta Sans-100.woff2) format('woff2');unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0300-0301, U+0303-0304, U+0308-0309, U+0323, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;}
        @font-face {font-family: 'Plus Jakarta Sans';font-style: normal;font-weight: 300;font-display: swap;src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/Plus Jakarta Sans/Plus Jakarta Sans-300.woff2) format('woff2');unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0300-0301, U+0303-0304, U+0308-0309, U+0323, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;}
		@font-face {font-family: 'Plus Jakarta Sans';font-style: normal;font-weight: 400;font-display: swap;src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/Plus Jakarta Sans/Plus Jakarta Sans-400.woff2) format('woff2');unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0300-0301, U+0303-0304, U+0308-0309, U+0323, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212;}
		@font-face {font-family: 'Plus Jakarta Sans';font-style: normal;font-weight: 500;font-display: swap;src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/Plus Jakarta Sans/Plus Jakarta Sans-500.woff2) format('woff2');unicode-range: U+0100-02AF, U+0300-0301, U+0303-0304, U+0308-0309, U+0323, U+0329, U+1E00-1EFF, U+2020, U+20A0-20AB, U+20AD-20CF, U+2113, U+2C60-2C7F, U+A720-A7FF;}
		@font-face {font-family: 'Plus Jakarta Sans';font-style: normal;font-weight: 700;font-display: swap;src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/Plus Jakarta Sans/Plus Jakarta Sans-700.woff2) format('woff2');unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0300-0301, U+0303-0304, U+0308-0309, U+0323, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;}
		@font-face {font-family: 'Plus Jakarta Sans';font-style: normal;font-weight: 900;font-display: swap;src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/Plus Jakarta Sans/Plus Jakarta Sans-900.woff2) format('woff2');unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0300-0301, U+0303-0304, U+0308-0309, U+0323, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;}
      </style>
    <![endif]-->
	<style type="text/css">
		@font-face {
        font-family: 'Plus Jakarta Sans';
        font-style: normal;
        font-weight: 300;
        font-display: swap;
        src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/jakarta/300.woff2) format('woff2');
        unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;
    }

    @font-face {
        font-family: 'Plus Jakarta Sans';
        font-style: normal;
        font-weight: 400;
        font-display: swap;
        src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/jakarta/400.woff2) format('woff2');
        unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;
    }

    @font-face {
        font-family: 'Plus Jakarta Sans';
        font-style: normal;
        font-weight: 500;
        font-display: swap;
        src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/jakarta/500.woff2) format('woff2');
        unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;
    }

    @font-face {
        font-family: 'Plus Jakarta Sans';
        font-style: normal;
        font-weight: 600;
        font-display: swap;
        src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/jakarta/600.woff2) format('woff2');
        unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;
    }

    @font-face {
        font-family: 'Plus Jakarta Sans';
        font-style: normal;
        font-weight: 700;
        font-display: swap;
        src: url(https://wso2.cachefly.net/wso2/sites/all/fonts/jakarta/700.woff2) format('woff2');
        unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, U+0329, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;
    }


    @font-face {
        font-family: 'Plus Jakarta Sans', Arial, Verdana, Helvetica, sans-serif;
        font-style: normal;
        font-weight: 400;
        src: local('Plus Jakarta Sans'),local('Plus Jakarta Sans'),format('Plus Jakarta Sans');
    }

		#outlook a {
			padding: 0;
		}

		.body {
			width: 100% !important;
			-webkit-text-size-adjust: 100%;
			-ms-text-size-adjust: 100%;
			margin: 0;
			padding: 0;
		}
		.cBackimg{background-color: #0d045c;}
		.ExternalClass {
			width: 100%;
		}

		.ExternalClass,
		.ExternalClass p,
		.ExternalClass span,
		.ExternalClass font,
		.ExternalClass td,
		.ExternalClass div {
			line-height: 100%;
		}

		img {
			outline: none;
			text-decoration: none;
			-ms-interpolation-mode: bicubic;
		}
		.viduraimage a img:hover{	transition: 0.3s !important;
			opacity: 0.8 !important;}

	 .wso2_orange a {
			color: #ff7300;
			text-decoration: underline;
		}

		.wso2_orange a:hover {
			text-decoration: none !important;
		}

		/* .Wrap_Border img:hover {
			background-color: #ff7300 !important;
		} */

.cFottop a:hover{color:  #0d045c !important;;}

		a.wso2_orange3:hover {

			text-decoration: none !important;
		}

		.wso2_orange3 a:hover {
			color: #ff7300 !important;
			text-decoration: none !important;
		}

		.Wrap_Border img:hover {
        opacity: 0.6 !important;
    	}
		.wso2_grey7 a:hover {
			text-decoration: none !important;
		}

		a img {
			border: none;
		}

		p {
			margin: 1em 0;
		}

		table td {
			border-collapse: collapse;
		}

		/* hide unsubscribe from forwards*/
		blockquote .original-only,
		.WordSection1 .original-only {
			display: none !important;
		}

		.fadeimg:hover {
			transition: 0.3s !important;
			opacity: 0.7 !important;
		}

		.linkname:hover {
			transition: 0.3s !important;
			opacity: 0.6 !important;

		}

		.linktopic:hover {
			transition: 0.3s !important;
			opacity: 0.8 !important;

		}

		.linkbody:hover {
			transition: 0.3s !important;
			text-decoration: none !important;
			color: #000000 !important;
		}

		.linkrevbut:hover {
			transition: 0.3s !important;
			text-decoration: none;
			background-color: #092a56;
			color: #ffffff !important;
			;
		}

		.AddtoCalender2:hover {
			transition: 0.3s !important;
			background-color: #53a99b !important;
			color: #fff !important;

		}

		.AddtoCalender:hover {
			transition: 0.3s !important;
			background-color: #1F78D1 !important;
			color: #fff !important;

		}

		.ctaorange:hover {
			transition: 0.3s !important;
			background-color: #ff7300 !important;
			color: #000!important;

		}

		.ctaorange1:hover {
			transition: 0.3s !important;
			background-color:#ff7300 !important;
			color: #000!important;
		}
		.footerContent a:hover {
				color: #ff7300!important;;
			}
		.wso2_center {
			text-align: center !important;
		}

		@media only screen and (max-width: 650px) {
			.fadeimg {
				width: 100% !important;
			}
			.cMobileImage{width: 100% !important;}
		}

		@media only screen and (max-width: 490px) {

			body,
			table,
			td,
			p,
			a,
			li,
			blockquote {
				-webkit-text-size-adjust: none !important;
			}
			.footerBlock{padding-left: 20px!important; padding-right: 20px!important;}
.SSborder{padding-left: 20px !important;
padding-right: 20px !important; padding-bottom: 0!important;}
.cForm{padding-bottom: 30px!important;}

			/* Prevent Webkit platforms from changing default text sizes */
			body {
				width: 100% !important;
				min-width: 100% !important;
			}
			.cMobileImage{width: 100% !important;}
			/* Prevent iOS Mail from adding padding to the body */

			#bodyCell {
				padding: 10px !important;
			}

			#templateContainer {
				/*              max-width:650px !important;*/
				width: 100% !important;
			}

			h1 {
				font-size: 24px !important;
				line-height: 100% !important;
			}
.cDottedline{margin-top: 32px!important;}
			h2 {
				font-size: 20px !important;
				line-height: 100% !important;
			}

			h3 {
				font-size: 28px !important;
				line-height: 100% !important;
			}

			h4 {
				font-size: 16px !important;
				line-height: 100% !important;
			}

			#templatePreheader {
				display: none !important;
			}

			/* Hide the template preheader to save space */


			.cP1 {
				padding-top: 10px !important;
			}

			.headerContent {
				font-size: 20px !important;
				line-height: 125% !important;
			}

			.bodyContent {
				font-size: 18px !important;
				line-height: 125% !important;
				padding-left: 20px !important;
				padding-right: 20px !important;
			}

			.templateColumnContainer {
				display: block !important;
				width: 100% !important;
			}

			.columnImage {
				height: auto !important;
				max-width: 480px !important;
				width: 100% !important;
			}

			.leftColumnContent {
				font-size: 16px !important;
				line-height: 125% !important;
			}

			.rightColumnContent {
				font-size: 16px !important;
				line-height: 125% !important;
			}

			.footerContent {
				font-size: 14px !important;
				line-height: 140% !important;
			}

			.viduraimage {
				display: inline;
				padding-bottom: 20px !important;
			}
			.viduraimage img { max-width: 277px !important;}


			.viduraname {
				display: inline;
				text-align: center !important;
			}

			.cRountable {
				padding-top: 0 !important;
			}

			.cSrinath {
				padding-bottom: 20px !important;
			}

			.vidurawso2 {
				display: inline;
			}

			/* Place footer social and utility links on their own lines, for easier access */
		}

		@media (prefers-color-scheme: dark) {
		    p.VideoTitle{color:#333333!important;}
            .cBlueBack{background-color: #0d045c!important;}
			.cBackimg{background-color: #0d045c!important;}
			.footerContent{    color: #a2a3a4 !important;}
			.Summitfotter {
				background-color: #ced6e0 !important;
			}
			.cDayAwy{color: #ff7300!important;}
			.cDayAwy span{color: #ff7300!important;}


			.Summitfotter p {
				color: #000000 !important;
			}

			.Summitfotter p span {
				color: #000000 !important;
			}

			.bgtest {
				background-color: #0d045c !important;
			}
			.bgtestbotom {
				background-color: #0d045c !important;
			}



			.SSname {
				color: #719ce2 !important;
			}

			a.wso2_orange4:hover {
				text-decoration: none;
			}

			a.wso2_orange3 {
				color: #2b9ce9 !important;
				font-weight: 500!important
			}

			.SStime {
				color: #ff7300 !important;
			}

.bodyContentBullets{background-color: #333333 !important;}
			.Bodyconetntdark {
				background-color: #1f1f1f !important;
			}
            .Bodyconetntdark1{background-color: #0d045c !important;}
            .Bodyconetntdark2{background-color: #da207a !important;}
			p {
				color: #FFF !important;
			}
.cSesion1{background-color: #282f34!important;}
			p span{
				color: #ffffff !important;
			}


			li span {
				color: #ffffff !important;
			}

			.darklink {
				color: #ffffff !important;
			}

			.darklink:hover {
				transition: 0.3s !important;
				text-decoration: none !important;
				color: #ffffff !important;
			}

			.linkbody:hover {
				transition: 0.3s !important;
				text-decoration: none !important;
				color: #ffffff !important;
			}

			h2 {
				color: #ffffff !important;
			}
			h3 {
				color: #09b2e6 !important;
			}

			h2 a {
				color: #e2e2e2 !important;
			}
            a.cTextLink{color:#fff!important;}
			.fcp {
				color: #969696 !important;
			}

			.darkintro {
				color: #bbbdc1 !important;
			}

			.cPicks {
				color: #B1C7D8 !important;
			}

			.cSubs {
				color: #bdbdbd !important;
			}

			li {
				color: #ffffff !important;
			}

			.footerContent a {
				color: #969696 !important;
			}

			.darkfotterlink {
				color: #bbbdc1 !important;
			}

            .cTitleDark{
                color: #ff7300 !important;
            }

			.darkcommunity {
				background-color: #272727 !important;
			}

            .cHighlightText{
                color: #ffffff !important;
            }
			.cBox1{background-color: #17254d !important;}
			.cBox2{background-color: #002e42 !important;}
			.cBox3{background-color: #2c1048 !important;}
			.cBox4{background-color: #3c143c !important;}
		}

	</style>
</head>
<body class="wso2_body bgtest" style="font-family: 'Plus Jakarta Sans', Helvetica,sans-serif; -ms-text-size-adjust: 100%; height: 100% !important; width: 100% !important; margin: 0; padding: 0;" data-gr-c-s-loaded="true" bgcolor="#0d045c">
<table align="center" border="0" cellpadding="0" cellspacing="0" class="wso2_full_wrap bgtest" style="-ms-text-size-adjust: 100%;-webkit-text-size-adjust: 100%;height: 100% !important;margin: 0;mso-table-lspace: 0pt;mso-table-rspace: 0pt;padding: 0;" width="100%">
	<tbody>
		<tr>
			<td align="center" id="bodyCell" style="-webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; mso-table-lspace: 0pt; mso-table-rspace: 0pt;margin: 0;" valign="top"><!-- BEGIN TEMPLATE // -->
			<table cellpadding="0" cellspacing="0" id="templateContainer" style="-webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; mso-table-lspace: 0pt; mso-table-rspace: 0pt;" width="100%">
				<tbody>
					<tr>
						<td align="center" bgcolor="#0d045c" class="bgtest cBackimg" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;margin: 0;height: 275px;" valign="top">
						<table cellpadding="0" cellspacing="0" id="templateContainer" style="-webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; mso-table-lspace: 0pt; mso-table-rspace: 0pt;" width="100%">
							<tbody>
								<tr>
									<td align="center" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;width: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;" valign="top"><!-- BEGIN PREHEADER // -->
									<table border="0" cellpadding="0" cellspacing="0" id="templatePreheader" style="-ms-text-size-adjust: 100%;-webkit-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;" width="100%">
										<tbody>
											<tr>
												<td align="center" class="wso2_orange preheaderContent" style="color: rgb(255, 255, 255); font-family: Roboto, Helvetica, sans-serif; font-size: 10px; line-height: 12.5px; text-align: center; padding: 0px; margin: 0px; overflow: hidden; display: none;" valign="top">Your WSO2Con Asia 2025 Digital Pass is Here!</td>
											</tr>
										</tbody>
									</table>
									<!-- // END PREHEADER --></td>
								</tr>
								<tr>
									<td align="center" valign="top">
									<table border="0" cellpadding="0" cellspacing="0" class="cBlueBack" id="m_2377566871920059920templateHeader" style="max-width:650px;margin-top: 20px;" width="100%">
										<tbody>
											<tr>
												<td align="left" class="headerContent" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #505050;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 20px;line-height: 20px;vertical-align: middle;padding: 40px 0 0px 10px;text-align: left;" valign="top">&nbsp;</td>
												<td align="right" class="headerContent" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #fff;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 20px;font-weight: bold;line-height: 39px;text-align: right;vertical-align: middle;padding: 30px 0 0 0;width: 260px;/*! border-bottom: #fff 1px solid; */" valign="top">
												</td>
												<!-- <td align="right" class="wso2_orange preheaderContent" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #949494;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 11px;line-height: 12.5px;text-align: right;padding: 20px 10px 30px 0;vertical-align: middle;" valign="top"><a href="{{view_online}}" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;color: #1e1e1e;font-weight: normal;text-decoration: underline;" target="_blank">View online</a></td> -->
											</tr>
										</tbody>
									</table>
									</td>
								</tr>
								<tr>
									<td align="center" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;width: 100%;" valign="top" width="100%"><!-- BEGIN BODY // -->
									<table bgcolor="#0d045c" border="0" cellpadding="0" cellspacing="0" class="Bodyconetntdark" id="templateBody" style="width: 100%;max-width: 650px;-ms-text-size-adjust: 100%;-webkit-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;margin: auto;border-radius: 15px 15px 0px 0px; margin-top: 10px;" width="100%">
										<tbody>
											<tr>
												<td align="center" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #ffffff;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 16px;line-height: 5px;text-align: center;margin: 0px;box-shadow: 0px 0px 26px 0 rgb(0 0 0 / 57%);border-radius: 15px 15px 0px 0px;" valign="top">
												<table align="left" border="0" cellpadding="0" cellspacing="0" style="text-align: left;margin-bottom: 0;" width="100%">
													<tbody>
														<tr>
															<td align="center" class="SSborder" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #ffffff;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 16px;line-height: 5px;text-align: center;margin: 0px 0px 0px 0px;padding: 0px 0px 0px 0px;" valign="top"><a href="https://wso2.com/wso2con/2025/asia/agenda/" target="_blank" style="text-decoration:none;"><img alt="WSO2Con 2025" class="darkLogo" height="40" id="headerImage" src="https://wso2.cachefly.net/wso2/sites/all/image_resources/con-mailer-banner-v4.png" style="border-radius: 15px 15px 0 0; width: 650px;-ms-interpolation-mode: bicubic; border-top: solid 1px #123989;height: auto;outline: none;text-decoration: none;font-size: 12px; font-weight: 400;text-align: left; padding-top: 0px; padding-bottom: 0px;" width="650"></a></td>
														</tr>
													</tbody>
												</table>
												</td>
											</tr>
										</tbody>
									</table>
									</td>
								</tr>
							</tbody>
						</table>
						</td>
					</tr>
					<tr>
						<td align="left" bgcolor="#0d045c" class="bgtest" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;width: 100%;padding: 0px 0 0;" valign="top" width="100%"><!-- BEGIN BODY // -->
						<table bgcolor="#ffffff" border="0" cellpadding="0" cellspacing="0" class="Bodyconetntdark" id="templateBody" style="width: 100%;max-width: 650px;-ms-text-size-adjust: 100%;-webkit-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;margin: auto;border-radius: 0 0 15px 15px;" width="100%">
							<tbody>
								<tr>
									<td align="left" class="bodyContent" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #0d045c;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;text-align: left;padding: 40px 40px 40px 40px; border-radius: 15px;" valign="top">
									<p style="font-family: Plus Jakarta Sans, Helvetica, sans-serif; padding-bottom: 0px; font-size: 16px; line-height: 28px; padding-left: 0px; padding-right: 0px; color: rgb(13, 4, 92); margin-bottom: 0px; margin-top: 0px; text-align: center;">Dear Attendee,</p>

									<p style="font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;padding-bottom: 0px;font-size: 16px;line-height: 28px;padding-left: 0;padding-right: 0;padding-right: 0;color: #0d045c;text-align: center;margin-bottom: 0;">Get ready for WSO2Con Asia 2025, happening July 29-31 in Colombo, Sri Lanka! We're excited to welcome you.</p>
									<!-- <p style="font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;padding-bottom: 0px;font-size: 16px;line-height: 28px;padding-left: 0;padding-right: 0;padding-right: 0;color: #0d045c;text-align: center;margin-bottom: 0;">To make your experience seamless, we've issued you a unique, digitally signed verifiable credential, powered by WSO2 Identity Server. This credential, which you'll find as a QR code below, is your key to quick and easy access at the event.</p> -->

                                    <table align="left" border="0" cellpadding="0" cellspacing="0" class="cMobilePadding cButtonCenterMobile cButton" style="width:100%; background-color: #f9f9f9; margin-top: 30px; margin-bottom: 15px; border-radius: 10px; " width="100%">
                                        <tbody>
                                            <tr>
                                                <td style="padding: 30px; text-align: center;">
                                                <p style="font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;padding-bottom: 0px;font-size: 16px;line-height: 28px;padding-left: 0;padding-right: 0;padding-right: 0;color: #000000 !important;text-align: center;margin-bottom: 20px; margin-top: 0; font-weight: 500;">To make your experience seamless, we've issued you a QR code for quick and easy event access.</p>
                                                <!-- [QR_IMAGE] -->
												<p style="font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;padding-bottom: 0px;font-size: 16px;line-height: 28px;padding-left: 0;padding-right: 0;padding-right: 0;color: #000000 !important;text-align: center;margin-bottom: 0px; margin-top: 20px; font-weight: 500;">Simply scan this QR code at the on-site registration counter to enter the conference venue.</p>

                                                </td>
                                            </tr>
                                        </tbody>
                                    </table>


									<!-- <p style="font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;padding-bottom: 0px;font-size: 16px;line-height: 28px;padding-left: 0;padding-right: 0;padding-right: 0;color: #0d045c;text-align: center;margin-bottom: 15px;">Don't forget to add WSO2Con Asia 2025 to your calendar and digital wallet:</p> -->

									<table align="center" border="0" cellpadding="0" cellspacing="0" class="cMobilePadding cButtonCenterMobile cButton" style="width:100%;" width="100%">
										<tbody>
											<tr>
												<td valign="top">
												<table align="center" border="0" cellpadding="0" cellspacing="0" style="width: 370px;background-color: transparent;padding-top: 0px; padding-top: 15px; padding-bottom: 15px;" width="280">
													<tbody>
														<tr>
															<td align="center" bgcolor="#ff7300" class="ctaorange"  pardot-data="" style="height: 50px; font-family: 'Plus Jakarta Sans', Helvetica, sans-serif; border-radius: 320px; font-weight: 600; font-size: 19px; background: rgb(255, 115, 0);" valign="middle">
																<a target="_blank" href="https://calendar.google.com/calendar/render?action=TEMPLATE&dates=20250729T023000Z%2F20250731T170000Z&details=WSO2Con%20Asia%202025%3A%20Celebrating%2020%20Years%20of%20Innovation%0Ahttps%3A%2F%2Fwso2con.com&location=Cinnamon%20Life%20at%20City%20of%20Dreams%2C%20Colombo%2C%20Sri%20Lanka&text=WSO2Con%20Asia%202025" style="line-height:45px;letter-spacing:1px;display:block ;text-decoration:none;color:#0d045c;">Add to Google Calendar</a></td>
														</tr>
													</tbody>
												</table>
												</td>
											</tr>
										</tbody>
									</table>


									<table align="center" border="0" cellpadding="0" cellspacing="0" class="cMobilePadding cButtonCenterMobile cButton" style="width:100%;" width="100%">
										<tbody>
											<tr>
												<td valign="top">
												<table align="center" border="0" cellpadding="0" cellspacing="0" style="width: 370px;background-color: transparent;padding-top: 0px; padding-top: 15px; padding-bottom: 15px;" width="280">
													<tbody>
														<tr>
															<td align="center" bgcolor="#ff7300" class="ctaorange"  pardot-data="" style="height: 50px; font-family: 'Plus Jakarta Sans', Helvetica, sans-serif; border-radius: 320px; font-weight: 600; font-size: 19px; background: rgb(255, 115, 0);" valign="middle">
																<a target="_blank" href="https://resources.wso2.com/l/142131/2025-07-23/c3czsm/142131/1753248068alImjpUK/ics_wso2con_asia_2025_2025_07_23_052040.ics" style="line-height:45px;letter-spacing:1px;display:block ;text-decoration:none;color:#0d045c;">Add to Apple/Outlook Calendar</a></td>
														</tr>
													</tbody>
												</table>
												</td>
											</tr>
										</tbody>
									</table>


									<table align="center" border="0" cellpadding="0" cellspacing="0" class="cMobilePadding cButtonCenterMobile cButton" style="width:100%;" width="100%">
										<tbody>
											<tr>
												<td valign="top">
												<table align="center" border="0" cellpadding="0" cellspacing="0" style="width: 370px;background-color: transparent;padding-top: 0px; padding-top: 15px; padding-bottom: 15px;" width="280">
													<tbody>
														<tr>
															<td align="center" bgcolor="#ff7300" class="ctaorange"  pardot-data="" style="height: 50px; font-family: 'Plus Jakarta Sans', Helvetica, sans-serif; border-radius: 320px; font-weight: 600; font-size: 19px; background: rgb(255, 115, 0);" valign="middle"><!-- [WALLET_PASS_LINK] --></td>
														</tr>
													</tbody>
												</table>
												</td>
											</tr>
										</tbody>
									</table>




									<!-- <p style="font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;padding-bottom: 0px;font-size: 16px;line-height: 28px;padding-left: 0;padding-right: 0;padding-right: 0;color: #0d045c;text-align: center;margin-bottom: 0;">Download the WSO2Con app from the App Store or Google Play. Log in with your wso2.com credentials for event details and exclusive resources. No account? We've created one for you; expect login details via email shortly.</p> -->

									<p style="font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;padding-bottom: 0px;font-size: 16px;line-height: 28px;padding-left: 0;padding-right: 0;padding-right: 0;color: #0d045c;text-align: center;margin-bottom: 0; margin-top: 15px;">We can't wait to see you there!</p>

									<p style="margin-bottom: 0.5rem;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 16px;line-height: 28px;padding-top: 0;padding-left: 0;padding-right: 0;padding-right: 0;color: #0d045c;text-align: center;padding-top: 0px; margin-bottom: 0px;">Best regards,<br>
									The WSO2 Team</p>
									</td>
								</tr>
							</tbody>
						</table>
						</td>
					</tr>
					<tr>
						<td align="center" bgcolor="#0d045c" class="bgtest removePadding" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;/* background-color: #ffffff; */padding: 60px 0px;" valign="top"><!-- BEGIN FOOTER // -->
						<table border="0" cellpadding="0" cellspacing="0" id="templateFooter" style="-ms-text-size-adjust: 100%;-webkit-text-size-adjust: 100%;/* background-color: #ffffff; */border-collapse: collapse !important;mso-table-lspace: 0pt;mso-table-rspace: 0pt;max-width: 650px;" width="100%">
							<tbody>
								<tr>
									<td align="center" bgcolor="#0d045c" class="bgtest footerBlock" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;/* background-color: #ffffff; */padding: 0px 42px 0px 50px;" valign="top"><!-- BEGIN FOOTER // -->
									<table border="0" cellpadding="0" cellspacing="0" id="templateFooter" style="-ms-text-size-adjust: 100%;-webkit-text-size-adjust: 100%;/* background-color: #ffffff; */border-collapse: collapse !important;mso-table-lspace: 0pt;mso-table-rspace: 0pt;" width="100%">
										<tbody>
											<tr>
												<td align="left" class="Wrap_Border footerContent leftMarginMobile cWhiteSocialIcon" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #606060;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 10px;line-height: 14px;text-align:left;padding: 0px 0 20px;" valign="top"><a href="https://twitter.com/wso2" style="-webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; color: #606060; font-weight: normal; text-decoration: underline;padding-right: 10px;"><img align="middle" alt="WSO2 Twitter" src="https://wso2.cachefly.net/wso2/sites/all/2024/images/x-footer-mailer-icons-w.png" style="width: 30px; -ms-interpolation-mode: bicubic; height: auto; outline: none; text-decoration: none; border: 0; text-align: center;border-radius: 15px;"></a> &nbsp;&nbsp;&nbsp; <a href="https://www.facebook.com/OfficialWSO2" style="-webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; color: #606060; font-weight: normal; text-decoration: underline;padding-right: 10px;"><img align="middle" alt="WSO2 Facebook" src="https://wso2.cachefly.net/wso2/sites/all/2024/images/facebook-footer-mailer-icons-w.png" style=" width: 30px; -ms-interpolation-mode: bicubic; height: auto; outline: none; text-decoration: none; border: 0; text-align: center;border-radius: 15px;"></a> &nbsp;&nbsp;&nbsp; <a href="https://www.linkedin.com/company/wso2/" style="-webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; color: #606060; font-weight: normal; text-decoration: underline;padding-right: 10px;"><img align="middle" alt="WSO2 In" src="https://wso2.cachefly.net/wso2/sites/all/2024/images/linkdin-footer-mailer-icons-w.png" style="width: 30px;-ms-interpolation-mode: bicubic; height: auto; outline: none; text-decoration: none; border: 0; text-align: center;border-radius: 15px;"></a> &nbsp;&nbsp;&nbsp; <a href="https://www.instagram.com/officialwso2/" style="-webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; color: #606060; font-weight: normal; text-decoration: underline;padding-right: 10px;"><img align="middle" alt="WSO2 instagram" src="https://wso2.cachefly.net/wso2/sites/all/2024/images/insta-footer-mailer-icons-w.png" style="width: 30px; -ms-interpolation-mode: bicubic; height: auto; outline: none; text-decoration: none; border: 0; text-align: center;border-radius: 15px;"></a> &nbsp;&nbsp;&nbsp; <a href="https://www.youtube.com/user/WSO2TechFlicks?sub_confirmation=1" style="-webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; color: #606060; font-weight: normal; text-decoration: underline;padding-right: 10px;"><img align="middle" alt="WSO2 YT" src="https://wso2.cachefly.net/wso2/sites/all/2024/images/youtube-footer-mailer-icons-w.png" style="width: 30px; -ms-interpolation-mode: bicubic; height: auto; outline: none; text-decoration: none; border: 0; text-align: center;border-radius: 15px;"></a></td>
											</tr>
											<tr>
												<td align="left" class="headerContent leftMarginMobile" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #505050;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 20px;font-weight: bold;line-height: 20px;vertical-align: middle;padding: 20px 0 18px;" valign="top"><a href="https://wso2.com/" style="text-decoration:none;" target="_blank"><img alt="WSO2 Logo" height="40" id="headerImage" src="https://wso2.cachefly.net/wso2/sites/all/2024/images/wso2-one-color-logo-footer-w.png" style="width: 100px;-ms-interpolation-mode: bicubic;height: auto;outline: none;text-decoration: none;border: 0;" width="100"></a></td>
											</tr>
											<tr>
												<td align="left" class="wso2_orange3 footerContent leftMarginMobile" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #ffffff;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 13px;line-height: 18px;text-align: left;padding: 0 0px 20px;letter-spacing: 0.1px;" valign="top">© 2025 WSO2 LLC. All Rights Reserved</td>
											</tr>
											<tr>
												<td align="left" class="wso2_orange3 footerContent leftMarginMobile" style="-webkit-text-size-adjust: 100%;-ms-text-size-adjust: 100%;mso-table-lspace: 0pt;mso-table-rspace: 0pt;color: #ffffff;font-family: 'Plus Jakarta Sans', Helvetica,sans-serif;font-size: 13px;line-height: 18px;text-align: left;padding: 0 0px 20px;letter-spacing: 0.1px;" valign="top">This mail was sent by WSO2 LLC. 3080 Olcott St., Suite B202, Santa Clara, CA 95054, USA</td>
											</tr>
										</tbody>
									</table>
									</td>
								</tr>
							</tbody>
						</table>
						</td>
					</tr>
				</tbody>
			</table>
			<!-- // END BODY --><!-- // END TEMPLATE --></td>
		</tr>
	</tbody>
</table>
</body>

</html>
`

//
// Copyright 2018-2019 Amazon.com,
// Inc. or its affiliates. All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import AWSCore

protocol AWSMobileClientBehavior {
    func getCognitoCredentialsProvider() -> AWSCognitoCredentialsProvider
    func getIdentityId() -> AWSTask<NSString>
}
